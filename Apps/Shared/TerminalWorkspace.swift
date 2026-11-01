import Foundation
import Observation
import PocahontasKit

/// Owns connections independently of the currently mounted SwiftUI terminal view.
@MainActor @Observable
final class TerminalWorkspace {
  private(set) var sessions: [TerminalController] = []
  private(set) var selectedID: UUID?
  private var nextNumber = 1
  private var connecting: [UUID: Task<Void, Never>] = [:]

  var selected: TerminalController? { sessions.first { $0.id == selectedID } }

  func showNewConnection() {
    selected?.leaveInput()
    selectedID = nil
  }

  func select(_ id: UUID) {
    guard sessions.contains(where: { $0.id == id }), selectedID != id else { return }
    selected?.leaveInput()
    selectedID = id
  }

  func selectNext(backwards: Bool = false) {
    guard !sessions.isEmpty else { return }
    let index = sessions.firstIndex { $0.id == selectedID }
    let next =
      index.map { ($0 + (backwards ? -1 : 1) + sessions.count) % sessions.count }
      ?? (backwards ? sessions.count - 1 : 0)
    select(sessions[next].id)
  }

  @discardableResult
  func open(
    host: String, port: String, username: String, authentication: SSHAuthentication,
    stillAuthorized: @escaping @MainActor () -> Bool = { true }
  ) -> TerminalController {
    let terminal = TerminalController()
    terminal.number = nextNumber
    nextNumber += 1
    terminal.title = host
    terminal.endpoint = "\(username)@\(host):\(port)"
    sessions.append(terminal)
    select(terminal.id)
    connecting[terminal.id] = Task { [weak self, weak terminal] in
      guard let self, let terminal, !Task.isCancelled else { return }
      await terminal.connect(
        host: host, port: port, username: username, authentication: authentication,
        stillAuthorized: stillAuthorized)
      self.connecting[terminal.id] = nil
    }
    return terminal
  }

  func openSaved(_ pending: PendingSavedConnection) {
    guard pending.generation == LibraryServices.shared.library?.accountGeneration else { return }
    open(
      host: pending.binding.host, port: String(pending.binding.port),
      username: pending.binding.username, authentication: pending.authentication,
      stillAuthorized: {
        pending.generation == LibraryServices.shared.library?.accountGeneration
      })
  }

  func close(_ id: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
    connecting.removeValue(forKey: id)?.cancel()
    sessions[index].disconnect()
    sessions.remove(at: index)
    if selectedID == id {
      selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
    }
  }

  func closeAll() {
    connecting.values.forEach { $0.cancel() }
    connecting.removeAll()
    sessions.forEach { $0.disconnect() }
    sessions.removeAll()
    selectedID = nil
  }

  func suspendAll(reason: String? = nil) {
    // Also cancel tasks which have not entered connect() yet.
    connecting.values.forEach { $0.cancel() }
    connecting.removeAll()
    for terminal in sessions {
      if let reason { terminal.suspend(reason: reason) } else { terminal.suspend() }
    }
  }
}
