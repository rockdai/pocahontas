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
    workspace.suspendAll(reason: "Account changed")
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
    workspace.suspendAll(reason: "Account changed")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(first.state, .disconnected)
    XCTAssertEqual(second.state, .disconnected)
    XCTAssertFalse(first.surface.hasLiveSurface)
    XCTAssertFalse(second.surface.hasLiveSurface)
    workspace.closeAll()
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
  private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<400 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("Timed out waiting for independent SSH output/state")
    throw CocoaError(.coderInvalidValue)
  }
}
