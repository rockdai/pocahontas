import Foundation
import Observation
import PocahontasKit

@MainActor @Observable
final class TerminalController: Identifiable {
  let id = UUID()
  var number = 0
  var endpoint = ""
  let surface = TerminalSurfaceView()
  #if os(iOS)
    let relay = TerminalInputRelay()
  #endif
  var state: SSHSessionState = .disconnected
  var title = "Terminal"
  var challenge: HostKeyChallenge?
  var pastePreview: String?
  private var trustReply: (@Sendable (Bool) -> Void)?
  private var session: SSHSession?
  private var generation = 0
  private struct ReconnectTarget {
    let connection: SSHConnection
    let credentials: SSHCredentials
    let stillAuthorized: @MainActor () -> Bool
  }
  // Credentials live only as long as this tab. They are never persisted by Quick Connect.
  private var reconnectTarget: ReconnectTarget?
  private var automaticallyReconnect = false
  private var activationTask: Task<Void, Never>?
  private var activationID: UUID?
  private var active = false
  private var lastAttempt: Date?

  var canReconnect: Bool {
    reconnectTarget != nil && state != .ready && state != .connecting
  }

  init() {
    #if os(iOS)
      relay.surface = surface
      surface.inputRelay = relay
    #endif
    surface.onPasteRequest = { [weak self] in self?.requestPaste($0) }
  }

  func connect(
    host: String, port: String, username: String, authentication: SSHAuthentication,
    stillAuthorized: @escaping @MainActor () -> Bool = { true }
  )
    async
  {
    disconnect()
    let token = generation
    title = host
    state = .connecting
    do {
      let connection = try SSHConnection(host: host, port: Int(port) ?? 0, username: username)
      let credentials = try await Task.detached(priority: .userInitiated) {
        try SSHCredentials(authentication: authentication)
      }.value
      guard generation == token, !Task.isCancelled else { return }
      guard stillAuthorized() else { throw LibraryError.accountChanged }
      let target = ReconnectTarget(
        connection: connection, credentials: credentials, stillAuthorized: stillAuthorized)
      reconnectTarget = target
      automaticallyReconnect = true
      start(target)
    } catch {
      if generation == token { state = .failed(error.localizedDescription) }
    }
  }

  private func start(_ target: ReconnectTarget) {
    guard target.stillAuthorized() else {
      disconnect()
      state = .failed(LibraryError.accountChanged.localizedDescription)
      return
    }
    stopTransport()
    let token = generation
    lastAttempt = Date()
    state = .connecting
    surface.ensureSurface()
    guard surface.hasLiveSurface else {
      state = .failed(TerminalError.creationFailed.localizedDescription)
      return
    }
    let size = surface.gridSize
    let session = SSHSession(
      connection: target.connection, credentials: target.credentials,
      size: .init(columns: size.columns, rows: size.rows),
      onTrust: { [weak self] challenge, reply in
        DispatchQueue.main.async {
          guard let self, self.generation == token else {
            reply(false)
            return
          }
          self.trustReply = reply
          self.challenge = challenge
        }
      },
      onOutput: { [weak self] data, acknowledge in
        DispatchQueue.main.async {
          defer { acknowledge() }
          guard let self, self.generation == token else { return }
          self.surface.inject(data)
        }
      },
      onTermination: { [weak self] reason in
        DispatchQueue.main.async {
          guard let self, self.generation == token else { return }
          if reason != .connectionLost { self.automaticallyReconnect = false }
          // Authentication and trust failures require a new, explicit connection.
          if reason == .rejected { self.reconnectTarget = nil }
        }
      },
      onState: { [weak self] state in
        DispatchQueue.main.async {
          guard let self, self.generation == token else { return }
          self.state = state
          self.surface.inputEnabled = state == .ready
          if state == .disconnected { self.session = nil }
          if case .failed = state { self.session = nil }
          if state != .connecting { self.answerTrust(false) }
        }
      })
    self.session = session
    surface.onPtyOutput = { [weak session] in session?.send($0) }
    surface.onGridResize = { [weak session] cols, rows in
      session?.resize(.init(columns: cols, rows: rows))
    }
    session.start()
  }

  /// Called only for the selected tab of an active window/scene. Repeated activation
  /// notifications share one probe; healthy sessions retain their shell and buffer.
  func activate() {
    active = true
    guard activationTask == nil, state != .connecting, reconnectTarget != nil else { return }
    let activationID = UUID()
    self.activationID = activationID
    activationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.activationID == activationID {
          self.activationTask = nil
          self.activationID = nil
        }
      }
      let token = self.generation
      if self.state == .ready, let session = self.session {
        if await session.checkConnection() { return }
      }
      // Coalesce fast focus changes without discarding a legitimate activation.
      if let lastAttempt = self.lastAttempt {
        let remaining = 2 - Date().timeIntervalSince(lastAttempt)
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
      }
      guard !Task.isCancelled, self.active, self.generation == token,
        self.automaticallyReconnect, let target = self.reconnectTarget
      else { return }
      self.start(target)
    }
  }

  func deactivate() {
    active = false
    cancelActivation()
  }

  private func cancelActivation() {
    activationTask?.cancel()
    activationTask = nil
    activationID = nil
  }

  func reconnect() {
    guard canReconnect, let target = reconnectTarget else { return }
    automaticallyReconnect = true
    start(target)
  }

  var status: String {
    switch state {
    case .connecting: "Connecting…"
    case .ready: "Connected"
    case .disconnected: "Disconnected"
    case .failed: "Connection stopped"
    }
  }

  func leaveInput() {
    #if os(iOS)
      surface.textInput.discardComposition()
      relay.sticky = .none
      _ = surface.resignFirstResponder()
    #else
      _ = surface.resignFirstResponder()
    #endif
    pastePreview = nil
  }

  func answerTrust(_ accepted: Bool) {
    let reply = trustReply
    trustReply = nil
    challenge = nil
    reply?(accepted)
  }

  private func stopTransport() {
    cancelActivation()
    generation += 1
    answerTrust(false)
    session?.stop()
    session = nil
    surface.inputEnabled = false
    surface.onPtyOutput = nil
    surface.onGridResize = nil
    leaveInput()
  }

  func disconnect() {
    active = false
    stopTransport()
    reconnectTarget = nil
    automaticallyReconnect = false
    lastAttempt = nil
    surface.destroySurface()
    state = .disconnected
  }

  func suspend(
    reason: String = "Disconnected in the background. Activate this session to reconnect.",
    allowReconnect: Bool = true
  ) {
    active = false
    if !allowReconnect {
      let wasRunning = state == .connecting || state == .ready
      disconnect()
      if wasRunning { state = .failed(reason) }
    } else if state == .connecting || state == .ready {
      stopTransport()
      lastAttempt = nil
      state = .failed(reason)
    }
  }

  func requestPaste(_ text: String) {
    guard state == .ready else { return }
    if text.contains("\n") || text.contains("\r") {
      pastePreview = text
    } else {
      surface.sendPaste(text)
    }
  }
  func confirmPaste() {
    if let pastePreview { surface.sendPaste(pastePreview) }
    pastePreview = nil
  }
}

private enum TerminalError: LocalizedError {
  case creationFailed
  var errorDescription: String? { "The terminal renderer could not be created." }
}
