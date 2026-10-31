import Foundation
import Observation
import PocahontasKit

@MainActor @Observable
final class TerminalController {
  let surface = TerminalSurfaceView()
  #if os(iOS)
    let relay = TerminalInputRelay()
  #endif
  var state: SSHSessionState = .disconnected
  var isPresented = false
  var title = "Terminal"
  var challenge: HostKeyChallenge?
  var pastePreview: String?
  private var trustReply: (@Sendable (Bool) -> Void)?
  private var session: SSHSession?
  private var generation = 0

  init() {
    #if os(iOS)
      relay.surface = surface
      surface.inputRelay = relay
    #endif
    surface.onPasteRequest = { [weak self] in self?.requestPaste($0) }
  }

  func connect(host: String, port: String, username: String, authentication: SSHAuthentication)
    async
  {
    disconnect()
    let token = generation
    isPresented = true
    title = host
    state = .connecting
    do {
      let connection = try SSHConnection(host: host, port: Int(port) ?? 0, username: username)
      let credentials = try await Task.detached(priority: .userInitiated) {
        try SSHCredentials(authentication: authentication)
      }.value
      guard generation == token else { return }
      surface.ensureSurface()
      guard surface.hasLiveSurface else { throw TerminalError.creationFailed }
      let size = surface.gridSize
      let session = SSHSession(
        connection: connection, credentials: credentials,
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
    } catch {
      if generation == token { state = .failed(error.localizedDescription) }
    }
  }

  func answerTrust(_ accepted: Bool) {
    let reply = trustReply
    trustReply = nil
    challenge = nil
    reply?(accepted)
  }

  func disconnect() {
    generation += 1
    answerTrust(false)
    session?.stop()
    session = nil
    surface.destroySurface()
    pastePreview = nil
    state = .disconnected
  }

  func suspend(
    reason: String =
      "Disconnected while in the background. Connect again to resume your remote tmux session."
  ) {
    if state == .connecting || state == .ready {
      disconnect()
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
