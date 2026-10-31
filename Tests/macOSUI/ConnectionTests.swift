import AppKit
import XCTest

/// Real native windows and loopback SSH, with original XCTest screenshots.
final class ConnectionTests: XCTestCase {
  @MainActor
  func testDesktopConnectionAndScreenshots() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      "-AppleInterfaceStyle", "Dark",
    ]
    app.launch()
    let window = app.windows.firstMatch
    XCTAssertTrue(app.textFields["connection.host"].waitForExistence(timeout: 10))
    replace(app.textFields["connection.host"], "")
    replace(app.textFields["connection.port"], "22")
    replace(app.textFields["connection.username"], "")
    capture("01-connection-empty", window)
    replace(app.textFields["connection.host"], "127.0.0.1")
    replace(
      app.textFields["connection.port"],
      ProcessInfo.processInfo.environment["POCAHONTAS_MAC_TEST_PORT"] ?? "62225")
    replace(app.textFields["connection.username"], "fixture")
    replace(app.secureTextFields["connection.password"], "pocahontas-test")
    capture("02-connection-password", window)

    app.radioButtons["SSH key"].click()
    capture("03-connection-key", window)
    let key = app.textViews["connection.key"]
    key.click()
    key.typeText("example-invalid-key")
    capture("04-connection-key-editor", window)
    app.buttons["connection.connect"].click()
    XCTAssertTrue(app.staticTexts["terminal.error"].waitForExistence(timeout: 10))
    capture("05-error-invalid-key", window)
    app.buttons["terminal.close"].click()
    app.radioButtons["SSH key"].click()
    app.buttons["connection.import"].click()
    XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
    capture("06-import-key-file", window)
    app.buttons["Cancel"].click()

    app.radioButtons["Password"].click()
    replace(app.secureTextFields["connection.password"], "pocahontas-test")
    app.buttons["connection.connect"].click()
    let trust = app.buttons["Trust and connect"]
    XCTAssertTrue(trust.waitForExistence(timeout: 15))
    capture("07-host-trust", window)
    app.buttons["Cancel"].click()
    XCTAssertTrue(app.staticTexts["terminal.error"].waitForExistence(timeout: 10))
    capture("08-error-trust-declined", window)
    app.buttons["terminal.close"].click()
    replace(app.secureTextFields["connection.password"], "pocahontas-test")
    app.buttons["connection.connect"].click()
    XCTAssertTrue(trust.waitForExistence(timeout: 10))
    trust.click()
    XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 20))
    capture("09-terminal-connected", window)

    let terminal = app.textViews["terminal.surface"]
    terminal.click()
    terminal.typeText("echo hello from pocahontas\r")
    capture("10-terminal-input", window)
    terminal.typeKey("a", modifierFlags: .command)
    terminal.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(
      (NSPasteboard.general.string(forType: .string) ?? "").contains("pocahontas SSH fixture"))
    capture("11-terminal-selection", window)

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      "cd ~/projects/pocahontas\ngit status\ntmux attach -t agent", forType: .string)
    terminal.typeKey("v", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["Paste multiple lines?"].waitForExistence(timeout: 5))
    capture("12-paste-preview", window)
    app.sheets.buttons["Paste"].click()
    capture("13-terminal-after-paste", window)

    // New windows have independent controllers. Closing the new connection leaves the first ready.
    app.typeKey("n", modifierFlags: .command)
    XCTAssertTrue(app.textFields["connection.host"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.windows.count, 2)
    capture("14-new-connection-window", app.windows.firstMatch)
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.windows.count, 1)

    app.buttons["terminal.close"].click()
    replace(app.secureTextFields["connection.password"], "wrong-password")
    app.buttons["connection.connect"].click()
    XCTAssertTrue(app.staticTexts["terminal.error"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.buttons["Trust and connect"].exists, "The accepted host pin must persist")
    capture("15-error-authentication", window)
    app.buttons["terminal.close"].click()
    replace(app.textFields["connection.port"], "0")
    replace(app.secureTextFields["connection.password"], "pocahontas-test")
    app.buttons["connection.connect"].click()
    XCTAssertTrue(app.staticTexts["terminal.error"].waitForExistence(timeout: 10))
    capture("16-error-invalid-port", window)
    app.terminate()
  }

  @MainActor private func replace(_ field: XCUIElement, _ text: String) {
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeText(XCUIKeyboardKey.delete.rawValue)
    if !text.isEmpty { field.typeText(text) }
  }
  @MainActor private func capture(_ name: String, _ window: XCUIElement) {
    let attachment = XCTAttachment(screenshot: window.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
