import AppKit
import GhosttyKit
import PocahontasKit
import Security
import XCTest

@testable import PocahontasMac

@MainActor
final class TerminalTests: XCTestCase {
  func testNativeKeyboardAndCompositionReachPTYExactlyOnce() async throws {
    let view = TerminalSurfaceView()
    let bytes = CapturedBytes()
    view.onPtyOutput = { bytes.append($0) }
    view.ensureSurface()
    defer { view.destroySurface() }
    XCTAssertTrue(view.hasLiveSurface)
    view.inputEnabled = true
    view.setMarkedText(
      "ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: .absent)
    view.setMarkedText(
      "n", selectedRange: NSRange(location: 1, length: 0), replacementRange: .absent)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(bytes.value.isEmpty, "Composition and candidate deletion must stay local")
    view.insertText("你好", replacementRange: .absent)
    view.unmarkText()
    view.keyDown(with: key(.c, characters: "\u{03}", modifiers: .control))
    view.keyDown(with: key(.up, characters: "\u{f700}"))
    view.keyDown(with: key(.a, characters: "a", modifiers: .option))
    for _ in 0..<100 {
      if bytes.value.suffix(2) == Data([0x1b, 0x61]) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(bytes.value, Data("你好\u{03}\u{1b}[A\u{1b}a".utf8))
    XCTAssertFalse(view.hasMarkedText())
    view.inputEnabled = false
    let count = bytes.value.count
    view.insertText("ignored", replacementRange: .absent)
    view.keyDown(with: key(.c, characters: "c"))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(bytes.value.count, count)
  }

  func testPasteResizeAndLightAppearance() async throws {
    let view = TerminalSurfaceView()
    let bytes = CapturedBytes()
    view.onPtyOutput = { bytes.append($0) }
    view.ensureSurface()
    defer { view.destroySurface() }
    view.inputEnabled = true
    view.inject(Data("\u{1b}[?2004h\u{1b}[?996n\u{1b}]11;?\u{1b}\\\u{1b}[6n".utf8))
    for _ in 0..<100 {
      if String(decoding: bytes.value, as: UTF8.self).contains("rgb:ffff/ffff/ffff") { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let reply = String(decoding: bytes.value, as: UTF8.self)
    XCTAssertTrue(reply.contains("\u{1b}[?997;2n"))
    XCTAssertTrue(reply.contains("rgb:ffff/ffff/ffff"))
    XCTAssertNotNil(reply.range(of: #"\u001B\[\d+;\d+R"#, options: .regularExpression))
    view.sendPaste("line one\nline two")
    for _ in 0..<100 {
      if bytes.value.suffix(6) == Data("\u{1b}[201~".utf8) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(bytes.value.range(of: Data("\u{1b}[200~line one\nline two\u{1b}[201~".utf8)))
    let old = view.gridSize
    view.frame.size.width /= 2
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    for _ in 0..<100 {
      if view.gridSize.columns < old.columns { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertLessThan(view.gridSize.columns, old.columns)
  }

  func testSelectionAndIndependentSurfaceLifetime() async throws {
    let first = TerminalController()
    let second = TerminalController()
    first.surface.ensureSurface()
    second.surface.ensureSurface()
    defer {
      first.disconnect()
      second.disconnect()
    }
    first.surface.inject(Data("first window".utf8))
    second.surface.inject(Data("second window".utf8))
    for _ in 0..<100 {
      second.surface.selectAll(nil)
      if second.surface.selectionText?.contains("second window") == true { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    first.disconnect()
    XCTAssertFalse(first.surface.hasLiveSurface)
    XCTAssertTrue(second.surface.hasLiveSurface)
    XCTAssertTrue(second.surface.selectionText?.contains("second window") == true)
    XCTAssertFalse(second.surface.selectionText?.contains("first window") == true)
  }

  func testHostTrustPersistsInRealMacKeychain() throws {
    let host = "pocahontas-test-\(UUID().uuidString):22"
    let store = KeychainKnownHosts()
    defer {
      SecItemDelete(
        [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: "com.rockdai.pocahontas.known-hosts",
          kSecAttrAccount as String: host,
          kSecUseDataProtectionKeychain as String: false,
          kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
    }
    XCTAssertNil(try store.key(for: host))
    try store.trust("ssh-ed25519 test-pin", for: host)
    XCTAssertEqual(try KeychainKnownHosts().key(for: host), "ssh-ed25519 test-pin")
    XCTAssertThrowsError(try store.trust("ssh-ed25519 different-pin", for: host))
  }

  private func key(_ key: Ghostty.Key, characters: String, modifiers: NSEvent.ModifierFlags = [])
    -> NSEvent
  {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
      charactersIgnoringModifiers: key == .c ? "c" : characters, isARepeat: false,
      keyCode: key.macKeyCode)!
  }
}

extension NSRange { fileprivate static let absent = NSRange(location: NSNotFound, length: 0) }
private final class CapturedBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  func append(_ data: Data) {
    lock.lock()
    bytes.append(data)
    lock.unlock()
  }
  var value: Data {
    lock.lock()
    defer { lock.unlock() }
    return bytes
  }
}
