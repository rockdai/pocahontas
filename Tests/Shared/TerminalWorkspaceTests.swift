import PocahontasKit
import XCTest

#if os(macOS)
  @testable import PocahontasMac
#else
  @testable import pocahontas
#endif

@MainActor
final class TerminalWorkspaceTests: XCTestCase {
  func testParallelSSHRetainsOutputAndSurvivesClosingOtherSession() async throws {
    guard let port = ProcessInfo.processInfo.environment["POCAHONTAS_SESSION_TEST_PORT"] else {
      throw XCTSkip("Run session-screenshots with the loopback fixture for SSH integration tests")
    }
    let workspace = TerminalWorkspace()
    defer { workspace.closeAll() }
    let first = workspace.open(
      host: "127.0.0.1", port: port, username: "fixture",
      authentication: .password("pocahontas-test"))
    try await ready(first)
    first.surface.sendPaste("SESSION_ONE")
    try await eventually { first.surface.textForTesting.contains("SESSION_ONE") }
    workspace.showNewConnection()
    XCTAssertEqual(first.state, .ready)
    let second = workspace.open(
      host: "127.0.0.1", port: port, username: "fixture",
      authentication: .password("pocahontas-test"))
    try await ready(second)
    second.surface.sendPaste("SESSION_TWO")
    try await eventually { second.surface.textForTesting.contains("SESSION_TWO") }
    // Unmounted terminals still consume SSH output, including while the new form is visible.
    first.surface.sendPaste("HIDDEN_OUTPUT")
    try await eventually { first.surface.textForTesting.contains("HIDDEN_OUTPUT") }
    XCTAssertFalse(second.surface.textForTesting.contains("SESSION_ONE"))
    XCTAssertFalse(first.surface.textForTesting.contains("SESSION_TWO"))
    workspace.select(first.id)
    XCTAssertEqual(first.state, .ready)
    XCTAssertEqual(second.state, .ready)
    XCTAssertTrue(first.surface.textForTesting.contains("SESSION_ONE"))
    workspace.close(first.id)
    XCTAssertFalse(first.surface.hasLiveSurface)
    XCTAssertEqual(workspace.selectedID, second.id)
    second.surface.sendPaste("STILL_CONNECTED")
    try await eventually { second.surface.textForTesting.contains("STILL_CONNECTED") }
    XCTAssertEqual(second.state, .ready)
    workspace.suspendAll(reason: "Account changed", allowReconnect: false)
    XCTAssertEqual(second.state, .failed("Account changed"))
    XCTAssertFalse(second.surface.hasLiveSurface)
  }

  func testFailedAuthenticationDoesNotDisconnectAnotherSession() async throws {
    guard let port = ProcessInfo.processInfo.environment["POCAHONTAS_SESSION_TEST_PORT"] else {
      throw XCTSkip("Run session-screenshots with the loopback fixture for SSH integration tests")
    }
    let workspace = TerminalWorkspace()
    defer { workspace.closeAll() }
    let good = workspace.open(
      host: "127.0.0.1", port: port, username: "fixture",
      authentication: .password("pocahontas-test"))
    try await ready(good)
    let bad = workspace.open(
      host: "127.0.0.1", port: port, username: "fixture", authentication: .password("wrong"))
    try await eventually {
      if case .failed = bad.state { return true }
      return false
    }
    XCTAssertEqual(good.state, .ready)
    let failure = bad.state
    workspace.activateSelected()
    XCTAssertFalse(bad.canReconnect)
    XCTAssertEqual(bad.state, failure)
    workspace.close(bad.id)
    good.surface.sendPaste("AFTER_AUTH_FAILURE")
    try await eventually { good.surface.textForTesting.contains("AFTER_AUTH_FAILURE") }
  }

  func testCloseBeforeScheduledConnectCannotCreateOrphanConnection() async throws {
    let workspace = TerminalWorkspace()
    let terminal = workspace.open(
      host: "127.0.0.1", port: "1", username: "fixture", authentication: .password("test"))
    workspace.close(terminal.id)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(workspace.sessions.isEmpty)
    XCTAssertNil(workspace.selectedID)
    XCTAssertEqual(terminal.state, .disconnected)
    XCTAssertFalse(terminal.surface.hasLiveSurface)
  }

  func testAccountChangeCancelsQueuedConnectionsInEveryTab() async throws {
    let workspace = TerminalWorkspace()
    let first = workspace.open(
      host: "127.0.0.1", port: "1", username: "fixture", authentication: .password("test"))
    let second = workspace.open(
      host: "127.0.0.1", port: "1", username: "fixture", authentication: .password("test"))
    workspace.suspendAll(reason: "Account changed", allowReconnect: false)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(first.state, .disconnected)
    XCTAssertEqual(second.state, .disconnected)
    XCTAssertFalse(first.surface.hasLiveSurface)
    XCTAssertFalse(second.surface.hasLiveSurface)
    workspace.closeAll()
  }

  func testActivationRecoversOnlySelectedSuspendedSessionAndRechecksAuthorization() async throws {
    guard let port = ProcessInfo.processInfo.environment["POCAHONTAS_SESSION_TEST_PORT"] else {
      throw XCTSkip("Requires loopback fixture")
    }
    let workspace = TerminalWorkspace()
    defer { workspace.closeAll() }
    var authorized = true
    let first = workspace.open(
      host: "127.0.0.1", port: port, username: "fixture",
      authentication: .password("pocahontas-test"), stillAuthorized: { authorized })
    try await ready(first)
    let second = workspace.open(
      host: "127.0.0.1", port: port, username: "fixture",
      authentication: .password("pocahontas-test"))
    try await ready(second)
    second.surface.sendPaste("BEFORE_SUSPEND")
    try await eventually { second.surface.textForTesting.contains("BEFORE_SUSPEND") }
    workspace.suspendAll()
    XCTAssertTrue(second.surface.hasLiveSurface)
    XCTAssertTrue(second.surface.textForTesting.contains("BEFORE_SUSPEND"))
    XCTAssertFalse(second.surface.inputEnabled)
    for _ in 0..<5 { workspace.activateSelected() }
    try await ready(second)
    XCTAssertNotEqual(first.state, .ready)
    second.surface.sendPaste("AFTER_RECONNECT")
    try await eventually { second.surface.textForTesting.contains("AFTER_RECONNECT") }
    authorized = false
    workspace.select(first.id)
    try await eventually { !first.canReconnect }
    XCTAssertFalse(first.surface.hasLiveSurface)
    XCTAssertNotEqual(first.state, .ready)
    workspace.suspendAll(reason: "Account changed", allowReconnect: false)
    workspace.activateSelected()
    XCTAssertFalse(second.canReconnect)
    XCTAssertFalse(second.surface.hasLiveSurface)
  }

  func testActivationRecoversSilentDropWithoutDuplicatingHealthySessions() async throws {
    guard let port = ProcessInfo.processInfo.environment["POCAHONTAS_SESSION_TEST_PORT"] else {
      throw XCTSkip("Requires loopback fixture")
    }
    let workspace = TerminalWorkspace()
    defer { workspace.closeAll() }
    let terminal = workspace.open(
      host: "127.0.0.1", port: port, username: "fixture",
      authentication: .password("pocahontas-test"))
    try await ready(terminal)
    terminal.surface.sendPaste("HEALTHY_SHELL")
    try await eventually { terminal.surface.textForTesting.contains("HEALTHY_SHELL") }
    for _ in 0..<5 { workspace.activateSelected() }
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(terminal.surface.textForTesting.contains("HEALTHY_SHELL"))
    terminal.surface.sendPaste("__POCAHONTAS_BLACKHOLE__")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(terminal.state, .ready)  // No TCP close or error has arrived.
    workspace.activateSelected()
    // The fixture clears the screen on each new shell; a fast handshake may move
    // through .connecting entirely between polling ticks.
    try await eventually { !terminal.surface.textForTesting.contains("HEALTHY_SHELL") }
    try await ready(terminal)
    terminal.surface.sendPaste("RECOVERED_SHELL")
    try await eventually { terminal.surface.textForTesting.contains("RECOVERED_SHELL") }
    XCTAssertEqual(workspace.sessions.count, 1)
    workspace.close(terminal.id)
    terminal.activate()
    XCTAssertFalse(terminal.canReconnect)
    XCTAssertFalse(terminal.surface.hasLiveSurface)
  }

  func testTransportDropRetriesOnTabSelectionButShellExitRequiresExplicitReconnect() async throws {
    guard let port = ProcessInfo.processInfo.environment["POCAHONTAS_SESSION_TEST_PORT"] else {
      throw XCTSkip("Requires loopback fixture")
    }
    let workspace = TerminalWorkspace()
    defer { workspace.closeAll() }
    let terminal = workspace.open(
      host: "127.0.0.1", port: port, username: "fixture",
      authentication: .password("pocahontas-test"))
    try await ready(terminal)
    terminal.surface.sendPaste("__POCAHONTAS_DROP__")
    try await eventually { terminal.state != .ready }
    workspace.showNewConnection()
    workspace.select(terminal.id)
    try await ready(terminal)
    terminal.surface.sendPaste("__POCAHONTAS_EXIT__")
    try await eventually { terminal.state != .ready }
    try await Task.sleep(for: .seconds(2))
    workspace.activateSelected()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(terminal.state, .disconnected)
    XCTAssertTrue(terminal.canReconnect)
    terminal.reconnect()
    try await ready(terminal)
  }

  func testClosingDuringActivationCannotReopenSession() async throws {
    guard let port = ProcessInfo.processInfo.environment["POCAHONTAS_SESSION_TEST_PORT"] else {
      throw XCTSkip("Requires loopback fixture")
    }
    let workspace = TerminalWorkspace()
    let terminal = workspace.open(
      host: "127.0.0.1", port: port, username: "fixture",
      authentication: .password("pocahontas-test"))
    try await ready(terminal)
    terminal.surface.sendPaste("__POCAHONTAS_BLACKHOLE__")
    try await Task.sleep(for: .milliseconds(100))
    workspace.activateSelected()
    try await Task.sleep(for: .milliseconds(100))
    workspace.closeAll()
    terminal.activate()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(terminal.state, .disconnected)
    XCTAssertFalse(terminal.surface.hasLiveSurface)
    XCTAssertFalse(terminal.canReconnect)
    XCTAssertTrue(workspace.sessions.isEmpty)
  }

  func testSelectionCloseAndWindowIsolation() {
    let firstWindow = TerminalWorkspace()
    let otherWindow = TerminalWorkspace()
    defer {
      firstWindow.closeAll()
      otherWindow.closeAll()
    }
    func open(_ workspace: TerminalWorkspace) -> TerminalController {
      workspace.open(
        host: "example.test", port: "22", username: "test", authentication: .password("test"))
    }
    let one = open(firstWindow)
    let two = open(firstWindow)
    let three = open(firstWindow)
    let other = open(otherWindow)
    firstWindow.selectNext()
    XCTAssertEqual(firstWindow.selectedID, one.id)
    firstWindow.selectNext(backwards: true)
    XCTAssertEqual(firstWindow.selectedID, three.id)
    firstWindow.close(two.id)  // Closing an inactive tab must not change selection.
    XCTAssertEqual(firstWindow.selectedID, three.id)
    firstWindow.close(three.id)
    XCTAssertEqual(firstWindow.selectedID, one.id)
    firstWindow.showNewConnection()
    firstWindow.select(UUID())
    XCTAssertNil(firstWindow.selectedID)
    firstWindow.closeAll()
    XCTAssertEqual(otherWindow.selectedID, other.id)
    XCTAssertEqual(otherWindow.sessions.count, 1)
  }

  #if os(iOS)
    func testSwitchingDiscardsIMEAndStickyModifiersWithoutDestroyingSurface() {
      let workspace = TerminalWorkspace()
      defer { workspace.closeAll() }
      let first = workspace.open(
        host: "example.test", port: "22", username: "test", authentication: .password("test"))
      first.surface.ensureSurface()
      first.surface.inputEnabled = true
      first.surface.textInput.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
      first.relay.toggle(.ctrl)
      workspace.showNewConnection()
      XCTAssertNil(first.surface.textInput.markedTextRange)
      XCTAssertTrue(first.relay.sticky.isEmpty)
      XCTAssertTrue(first.surface.hasLiveSurface)
    }
  #endif

  private func ready(_ terminal: TerminalController) async throws {
    try await eventually {
      if terminal.challenge != nil { terminal.answerTrust(true) }
      return terminal.state == .ready
    }
  }
  private func eventually(
    file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool
  ) async throws {
    for _ in 0..<400 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("Timed out waiting for independent SSH output/state", file: file, line: line)
    throw CocoaError(.coderInvalidValue)
  }
}
