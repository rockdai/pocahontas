import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSH

// All mutable session state lives on loop; only the outbound budget uses a lock.
public final class SSHSession: @unchecked Sendable {
  public typealias OutputHandler = @Sendable (Data, @escaping @Sendable () -> Void) -> Void
  public typealias TrustHandler =
    @Sendable (HostKeyChallenge, @escaping @Sendable (Bool) -> Void) -> Void
  private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  private let loop: EventLoop
  private let connection: SSHConnection
  private let credentials: SSHCredentials
  private let onState: @Sendable (SSHSessionState) -> Void
  private let onOutput: OutputHandler
  private let verifier: HostVerifier
  private let budget = WriteBudget()
  private var size: TerminalSize
  private var parent: Channel?
  private var child: Channel?
  private var pty: PTYHandler?
  private var timeout: Scheduled<Void>?
  private var started = false
  private var closed = false
  private var probe: EventLoopPromise<Bool>?
  private var probeTimeout: Scheduled<Void>?
  private let onTermination: @Sendable (SSHSessionTermination) -> Void

  public init(
    connection: SSHConnection, credentials: SSHCredentials,
    size: TerminalSize = .init(columns: 80, rows: 24),
    knownHosts: any KnownHostsStore = KeychainKnownHosts(),
    onTrust: @escaping TrustHandler,
    onOutput: @escaping OutputHandler,
    onTermination: @escaping @Sendable (SSHSessionTermination) -> Void = { _ in },
    onState: @escaping @Sendable (SSHSessionState) -> Void
  ) {
    self.connection = connection
    self.credentials = credentials
    self.size = size
    self.onOutput = onOutput
    self.onState = onState
    self.onTermination = onTermination
    loop = Self.group.next()
    verifier = HostVerifier(host: connection.hostIdentity, store: knownHosts, prompt: onTrust)
  }

  deinit { parent?.close(promise: nil) }

  public func start() {
    loop.execute { [self] in
      guard !started, !closed else { return }
      started = true
      onState(.connecting)
      timeout = loop.scheduleTask(in: .seconds(60)) { [weak self] in
        self?.finish(SSHSessionError.timeout)
      }
      let auth = AuthenticationDelegate(username: connection.username, credentials: credentials)
      let bootstrap = ClientBootstrap(group: loop)
        .connectTimeout(.seconds(15))
        .channelInitializer { [self] channel in
          let ssh = NIOSSHHandler(
            role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: verifier)),
            allocator: channel.allocator, inboundChildChannelInitializer: nil)
          do {
            try channel.pipeline.syncOperations.addHandlers(
              ssh,
              ConnectionErrors { [weak self] error in
                self?.finish(error)
              })
            return channel.eventLoop.makeSucceededVoidFuture()
          } catch { return channel.eventLoop.makeFailedFuture(error) }
        }
      bootstrap.connect(host: connection.host, port: connection.port).whenComplete {
        [self] result in
        switch result {
        case .failure(let error): finish(error)
        case .success(let channel):
          guard !closed else {
            channel.close(promise: nil)
            return
          }
          parent = channel
          channel.closeFuture.whenComplete { [weak self] _ in self?.finish(nil) }
          openTerminal(channel)
        }
      }
    }
  }

  private func openTerminal(_ channel: Channel) {
    guard !closed else { return }
    do {
      let handler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
      let promise = loop.makePromise(of: Channel.self)
      handler.createChannel(promise, channelType: .session) { [self] child, _ in
        guard !closed else { return child.eventLoop.makeFailedFuture(SSHSessionError.notReady) }
        let pty = PTYHandler(
          size: size,
          onReady: { [weak self] in
            guard let self, !self.closed else { return }
            self.timeout?.cancel()
            self.timeout = nil
            self.onState(.ready)
          }, onOutput: onOutput,
          onClose: { [weak self] error in
            guard let self else { return }
            self.finish(error, reason: self.pty?.remoteExited == true ? .closed : .connectionLost)
          })
        self.pty = pty
        self.child = child
        return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
          .flatMap { child.pipeline.addHandler(pty) }
      }
      promise.futureResult.whenComplete { [self] result in
        if case .failure(let error) = result { finish(error) }
        if closed, case .success(let channel) = result { channel.close(promise: nil) }
      }
    } catch { finish(error) }
  }

  public func send(_ bytes: Data) {
    guard !bytes.isEmpty else { return }
    guard budget.reserve(bytes.count) else {
      loop.execute { [weak self] in self?.finish(SSHSessionError.bufferLimit) }
      return
    }
    loop.execute { [self] in
      guard !closed, let child else {
        budget.release(bytes.count)
        return
      }
      let buffer = child.allocator.buffer(bytes: bytes)
      child.writeAndFlush(buffer).whenComplete { [self] result in
        budget.release(bytes.count)
        if case .failure(let error) = result { finish(error) }
      }
    }
  }

  public func resize(_ size: TerminalSize) {
    loop.execute { [self] in
      guard !closed else { return }
      self.size = size
      if let child { pty?.resize(size, on: child) }
    }
  }

  /// Opening and immediately closing an empty SSH channel checks the existing transport
  /// without writing to the terminal or executing a command. Even a channel-limit rejection
  /// proves the peer is alive. A deadline also catches silently dropped TCP connections.
  public func checkConnection(timeout: TimeAmount = .seconds(5)) async -> Bool {
    let result = loop.makePromise(of: Bool.self)
    loop.execute { [self] in
      guard !closed, let parent, parent.isActive, let pty, pty.phase == .running else {
        result.succeed(false)
        return
      }
      if let probe {
        probe.futureResult.cascade(to: result)
        return
      }
      probe = result
      probeTimeout = loop.scheduleTask(in: timeout) { [weak self] in
        self?.finish(SSHSessionError.connectionLost)
      }
      do {
        let handler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        let opened = loop.makePromise(of: Channel.self)
        handler.createChannel(opened, channelType: .session) { channel, _ in
          channel.eventLoop.makeSucceededVoidFuture()
        }
        opened.futureResult.whenComplete { [weak self] outcome in
          if case .success(let channel) = outcome { channel.close(promise: nil) }
          guard let self, !self.closed else { return }
          switch outcome {
          case .success: self.completeProbe(true)
          case .failure(let error):
            if let sshError = error as? NIOSSHError, sshError.type == .channelSetupRejected {
              self.completeProbe(true)
            } else {
              self.finish(error)
            }
          }
        }
      } catch { finish(error) }
    }
    return (try? await result.futureResult.get()) ?? false
  }

  private func completeProbe(_ alive: Bool) {
    probeTimeout?.cancel()
    probeTimeout = nil
    let pending = probe
    probe = nil
    pending?.succeed(alive)
  }

  public func stop() { loop.execute { [self] in finish(nil, reason: .closed) } }

  private func finish(_ error: Error?, reason: SSHSessionTermination = .connectionLost) {
    loop.preconditionInEventLoop()
    guard !closed else { return }
    closed = true
    timeout?.cancel()
    timeout = nil
    verifier.cancel()
    child?.close(promise: nil)
    parent?.close(promise: nil)
    child = nil
    parent = nil
    pty = nil
    let termination: SSHSessionTermination
    if let error = error as? NIOSSHError {
      termination =
        error.type == .tcpShutdown || error.type == .creatingChannelAfterClosure
        ? .connectionLost : .rejected
    } else if let error = error as? SSHSessionError {
      switch error {
      case .hostKeyRejected, .hostKeyChanged, .authenticationRejected, .startupRejected:
        termination = .rejected
      default: termination = reason
      }
    } else {
      termination = reason
    }
    onTermination(termination)
    onState(error.map { .failed(Self.describe($0)) } ?? .disconnected)
    completeProbe(false)
  }

  private static func describe(_ error: Error) -> String {
    if let error = error as? LocalizedError, let description = error.errorDescription {
      return description
    }
    if let error = error as? NIOSSHError {
      if error.type == .tcpShutdown || error.type == .creatingChannelAfterClosure {
        return "The SSH connection was lost. Activate this session or reconnect to continue."
      }
      return "SSH negotiation or authentication failed. Check the server and credentials."
    }
    return error.localizedDescription
  }
}

private final class AuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate,
  @unchecked Sendable
{
  let username: String
  let credentials: SSHCredentials
  var offered = false
  init(username: String, credentials: SSHCredentials) {
    self.username = username
    self.credentials = credentials
  }
  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    guard !offered else {
      nextChallengePromise.fail(SSHSessionError.authenticationRejected)
      return
    }
    offered = true
    let supported: Bool
    switch credentials.offer {
    case .password: supported = availableMethods.contains(.password)
    case .privateKey: supported = availableMethods.contains(.publicKey)
    default: supported = false
    }
    if supported {
      nextChallengePromise.succeed(
        .init(username: username, serviceName: "", offer: credentials.offer))
    } else {
      nextChallengePromise.fail(SSHSessionError.authenticationRejected)
    }
  }
}

private final class HostVerifier: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
  let host: String
  let store: any KnownHostsStore
  let prompt: SSHSession.TrustHandler
  var pending: EventLoopPromise<Void>?
  init(host: String, store: any KnownHostsStore, prompt: @escaping SSHSession.TrustHandler) {
    self.host = host
    self.store = store
    self.prompt = prompt
  }
  func validateHostKey(
    hostKey: NIOSSHPublicKey, validationCompletePromise promise: EventLoopPromise<Void>
  ) {
    do {
      let presented = String(openSSHPublicKey: hostKey)
      switch try HostKeyDecision.evaluate(known: store.key(for: host), presented: presented) {
      case .trusted: promise.succeed(())
      case .changed(let previous, let fingerprint):
        promise.fail(SSHSessionError.hostKeyChanged(previous: previous, presented: fingerprint))
      case .firstUse(let fingerprint):
        pending = promise
        prompt(.init(host: host, fingerprint: fingerprint)) { [weak self] accepted in
          guard let self else { return }
          promise.futureResult.eventLoop.execute {
            guard let pending = self.pending else { return }
            self.pending = nil
            do {
              guard accepted else { throw SSHSessionError.hostKeyRejected }
              try self.store.trust(presented, for: self.host)
              pending.succeed(())
            } catch { pending.fail(error) }
          }
        }
      }
    } catch { promise.fail(error) }
  }
  func cancel() {
    pending?.fail(SSHSessionError.hostKeyRejected)
    pending = nil
  }
}

private final class ConnectionErrors: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = Never
  let onError: @Sendable (Error) -> Void
  init(_ onError: @escaping @Sendable (Error) -> Void) { self.onError = onError }
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    onError(error)
    context.close(promise: nil)
  }
}

private final class WriteBudget: @unchecked Sendable {
  let lock = NSLock()
  var bytes = 0
  func reserve(_ count: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard count <= 1024 * 1024 - bytes else { return false }
    bytes += count
    return true
  }
  func release(_ count: Int) {
    lock.lock()
    bytes -= count
    lock.unlock()
  }
}
