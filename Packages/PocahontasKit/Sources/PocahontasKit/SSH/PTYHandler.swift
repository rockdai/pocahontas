import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

// Mutable state is confined to the channel's event loop.
final class PTYHandler: ChannelDuplexHandler, @unchecked Sendable {
  typealias InboundIn = SSHChannelData
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = SSHChannelData

  enum Phase { case idle, pty, shell, running, closed }
  private(set) var phase = Phase.idle
  private var size: TerminalSize
  private var requestedSize: TerminalSize
  private var pendingBytes = 0
  private var paused = false
  private var exitError: Error?
  private let onReady: @Sendable () -> Void
  private let onOutput: SSHSession.OutputHandler
  private let onClose: @Sendable (Error?) -> Void

  init(
    size: TerminalSize, onReady: @escaping @Sendable () -> Void,
    onOutput: @escaping SSHSession.OutputHandler,
    onClose: @escaping @Sendable (Error?) -> Void
  ) {
    self.size = size
    requestedSize = size
    self.onReady = onReady
    self.onOutput = onOutput
    self.onClose = onClose
  }

  func channelActive(context: ChannelHandlerContext) {
    phase = .pty
    request(
      SSHChannelRequestEvent.PseudoTerminalRequest(
        wantReply: true, term: "xterm-256color", terminalCharacterWidth: size.columns,
        terminalRowHeight: size.rows, terminalPixelWidth: 0, terminalPixelHeight: 0,
        terminalModes: .init([.ECHO: 1, .ICANON: 1, .ISIG: 1])
      ), context: context)
    context.fireChannelActive()
  }

  private func request(_ event: Any, context: ChannelHandlerContext) {
    let promise = context.eventLoop.makePromise(of: Void.self)
    let channel = context.channel
    promise.futureResult.whenFailure { error in channel.pipeline.fireErrorCaught(error) }
    context.triggerUserOutboundEvent(event, promise: promise)
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case is ChannelSuccessEvent:
      if phase == .pty {
        phase = .shell
        request(SSHChannelRequestEvent.ShellRequest(wantReply: true), context: context)
      } else if phase == .shell {
        phase = .running
        if size != requestedSize { sendResize(context: context) }
        onReady()
      }
    case is ChannelFailureEvent:
      if phase == .pty || phase == .shell {
        errorCaught(context: context, error: SSHSessionError.startupRejected)
      }
    case let status as SSHChannelRequestEvent.ExitStatus:
      if status.exitStatus != 0 { exitError = RemoteExit(status: status.exitStatus) }
    case ChannelEvent.inputClosed:
      context.close(promise: nil)
    default: context.fireUserInboundEventTriggered(event)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard phase != .closed, case .byteBuffer(let buffer) = unwrapInboundIn(data).data else {
      return
    }
    let bytes = Data(buffer.readableBytesView)
    guard !bytes.isEmpty else { return }
    guard bytes.count <= 2 * 1024 * 1024 - pendingBytes else {
      errorCaught(context: context, error: SSHSessionError.bufferLimit)
      return
    }
    pendingBytes += bytes.count
    let channel = context.channel
    if pendingBytes >= 512 * 1024, !paused {
      paused = true
      channel.setOption(ChannelOptions.autoRead, value: false).whenFailure {
        channel.pipeline.fireErrorCaught($0)
      }
    }
    let acknowledgement = OutputAcknowledgement { [weak self] in
      guard let self else { return }
      channel.eventLoop.execute {
        guard self.phase != .closed else { return }
        self.pendingBytes -= bytes.count
        if self.paused, self.pendingBytes < 256 * 1024 {
          self.paused = false
          channel.setOption(ChannelOptions.autoRead, value: true).whenFailure {
            channel.pipeline.fireErrorCaught($0)
          }
        }
      }
    }
    onOutput(bytes, { acknowledgement.complete() })
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    context.write(
      wrapOutboundOut(.init(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))),
      promise: promise)
  }

  func resize(_ size: TerminalSize, on channel: Channel) {
    guard self.size != size else { return }
    self.size = size
    if phase == .running {
      requestedSize = size
      channel.triggerUserOutboundEvent(Self.resizeEvent(size), promise: nil)
    }
  }

  private func sendResize(context: ChannelHandlerContext) {
    requestedSize = size
    context.triggerUserOutboundEvent(Self.resizeEvent(size), promise: nil)
  }

  private static func resizeEvent(_ size: TerminalSize)
    -> SSHChannelRequestEvent.WindowChangeRequest
  {
    .init(
      terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
      terminalPixelWidth: 0, terminalPixelHeight: 0)
  }

  func channelInactive(context: ChannelHandlerContext) {
    finish(exitError)
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    finish(error)
    context.close(promise: nil)
  }

  private func finish(_ error: Error?) {
    guard phase != .closed else { return }
    phase = .closed
    onClose(error)
  }
}

private struct RemoteExit: LocalizedError {
  let status: Int
  var errorDescription: String? { "The remote shell exited with status \(status)." }
}

private final class OutputAcknowledgement: @unchecked Sendable {
  private let lock = NSLock()
  private var callback: (@Sendable () -> Void)?
  init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
  func complete() {
    lock.lock()
    let action = callback
    callback = nil
    lock.unlock()
    action?()
  }
}
