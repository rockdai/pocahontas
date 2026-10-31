import GhosttyKit
import XCTest

@testable import pocahontas

@MainActor
final class TerminalTests: XCTestCase {
  func testSavedConnectionRechecksAccountBeforeStartingSSH() async {
    let terminal = TerminalController()
    await terminal.connect(
      host: "127.0.0.1", port: "22", username: "fixture",
      authentication: .password("test-only"), stillAuthorized: { false })
    guard case .failed = terminal.state else { return XCTFail("Account change must block SSH") }
    XCTAssertFalse(terminal.surface.hasLiveSurface)
  }
  func testCompositionCommitsExactlyOnceAndDoesNotDeleteRemoteText() {
    let view = TerminalTextInputView()
    var commits: [String] = []
    var deletes = 0
    view.onCommit = { commits.append($0) }
    view.onDelete = { deletes += 1 }
    view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
    XCTAssertTrue(commits.isEmpty)
    view.deleteBackward()
    XCTAssertEqual(deletes, 0)
    view.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
    view.unmarkText()
    view.textViewDidChange(view)
    XCTAssertEqual(commits, ["你"])
    view.deleteBackward()
    XCTAssertEqual(deletes, 1)
  }

  func testGhosttyRepliesAndEncodesInputThroughPassthru() async {
    let view = TerminalSurfaceView()
    let bytes = CapturedBytes()
    view.onPtyOutput = { bytes.append($0) }
    view.ensureSurface()
    defer { view.destroySurface() }
    XCTAssertTrue(view.hasLiveSurface)
    view.inputEnabled = true
    view.inject(Data("\u{1b}[6n".utf8))
    view.sendKey(.c, mods: .ctrl)
    view.insertText("你好")
    for _ in 0..<100 {
      if bytes.value.contains(3), bytes.value.range(of: Data("你好".utf8)) != nil,
        bytes.value.contains(UInt8(ascii: "R"))
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(bytes.value.contains(3), "Ctrl-C must be encoded as ETX")
    XCTAssertNotNil(bytes.value.range(of: Data("你好".utf8)))
    XCTAssertNotNil(
      String(data: bytes.value, encoding: .utf8)?.range(
        of: #"\u001B\[\d+;\d+R"#, options: .regularExpression))
  }

  func testBracketedPasteAndResize() async {
    let view = TerminalSurfaceView()
    let bytes = CapturedBytes()
    view.onPtyOutput = { bytes.append($0) }
    view.ensureSurface()
    defer { view.destroySurface() }
    view.inputEnabled = true
    view.inject(Data("\u{1b}[?2004h".utf8))
    view.sendPaste("line one\nline two")
    for _ in 0..<100 {
      if bytes.value.range(of: Data("\u{1b}[201~".utf8)) != nil { break }
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(bytes.value.starts(with: Data("\u{1b}[200~".utf8)))
    XCTAssertTrue(bytes.value.suffix(6).elementsEqual(Data("\u{1b}[201~".utf8)))
    let old = view.gridSize
    view.frame.size.width /= 2
    view.setNeedsLayout()
    view.layoutIfNeeded()
    for _ in 0..<100 {
      if view.gridSize.columns < old.columns { break }
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertLessThan(view.gridSize.columns, old.columns)
    view.inputEnabled = false
    let count = bytes.value.count
    view.insertText("must not send")
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(bytes.value.count, count)
  }

  func testGhosttyReportsLightAppearanceToRemotePrograms() async {
    let view = TerminalSurfaceView()
    let bytes = CapturedBytes()
    view.onPtyOutput = { bytes.append($0) }
    view.ensureSurface()
    defer { view.destroySurface() }
    // Programs may detect either the color scheme (DSR) or background color (OSC 11).
    view.inject(Data("\u{1b}[?996n\u{1b}]11;?\u{1b}\\".utf8))
    let lightReport = Data("\u{1b}[?997;2n".utf8)
    for _ in 0..<100 {
      if bytes.value.range(of: lightReport) != nil,
        String(decoding: bytes.value, as: UTF8.self).contains("rgb:ffff/ffff/ffff")
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(bytes.value.range(of: lightReport))
    XCTAssertTrue(String(decoding: bytes.value, as: UTF8.self).contains("rgb:ffff/ffff/ffff"))
  }
}

private final class CapturedBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  func append(_ bytes: Data) {
    lock.lock()
    data.append(bytes)
    lock.unlock()
  }
  var value: Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}
