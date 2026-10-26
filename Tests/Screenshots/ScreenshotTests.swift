import UIKit
import XCTest

/// Captures the real app against the loopback fixture; no mock UI or production launch hooks.
final class ScreenshotTests: XCTestCase {
  @MainActor
  func testCaptureScreens() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    addUIInterruptionMonitor(withDescription: "Allow test clipboard paste") { alert in
      let allow = alert.buttons.matching(
        NSPredicate(format: "label IN %@", ["Allow Paste", "允许粘贴"])
      ).firstMatch
      if allow.exists {
        allow.tap()
        return true
      }
      return false
    }
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    XCTAssertTrue(app.textFields["connection.host"].waitForExistence(timeout: 10))
    capture("01-connection-empty", app)

    fillServer(app)
    let password = app.secureTextFields["connection.password"]
    password.tap()
    password.typeText("pocahontas-test")
    capture("02-connection-password-keyboard", app)
    password.typeText("\n")
    capture("03-connection-password-ready", app)

    app.buttons["SSH key"].tap()
    capture("04-connection-private-key", app)
    let key = app.textViews["connection.key"]
    key.tap()
    key.typeText("example-key-for-validation")
    capture("05-connection-key-editor", app)
    let passphrase = app.secureTextFields["Key passphrase (if encrypted)"]
    passphrase.tap()
    passphrase.typeText("\n")
    app.swipeUp()
    XCTAssertTrue(app.buttons["connection.connect"].isEnabled)
    app.buttons["connection.connect"].tap()
    XCTAssertTrue(app.staticTexts["terminal.error"].waitForExistence(timeout: 10))
    capture("06-error-invalid-key", app)
    app.buttons["Close"].tap()

    let importButton = app.buttons["Import Ed25519 key from Files"]
    importButton.tap()
    let browser = app.navigationBars["Browse"]
    XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
    capture("07-import-files", app)
    if app.buttons["Browse"].exists { app.buttons["Browse"].tap() }
    if browser.buttons["Browse"].exists { browser.buttons["Browse"].tap() }
    capture("08-import-locations", app)
    app.buttons["Cancel"].tap()

    app.buttons["Password"].tap()
    password.tap()
    password.typeText("pocahontas-test")
    app.buttons["connection.connect"].tap()
    let trust = app.alerts["Trust this server?"]
    XCTAssertTrue(trust.waitForExistence(timeout: 10))
    capture("09-host-trust-portrait", app)
    XCUIDevice.shared.orientation = .landscapeLeft
    capture("10-host-trust-landscape", app)
    XCUIDevice.shared.orientation = .portrait
    trust.buttons["Cancel"].tap()
    XCTAssertTrue(app.staticTexts["terminal.error"].waitForExistence(timeout: 10))
    capture("11-error-trust-declined", app)
    app.buttons["Close"].tap()

    password.tap()
    password.typeText("pocahontas-test")
    app.buttons["connection.connect"].tap()
    XCTAssertTrue(trust.waitForExistence(timeout: 10))
    trust.buttons["Trust and connect"].tap()
    XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 20))
    capture("12-terminal-connected", app)
    XCUIDevice.shared.orientation = .landscapeLeft
    capture("13-terminal-landscape", app)
    XCUIDevice.shared.orientation = .portrait

    // Enter through the actual terminal view so keyboard and accessory layout are visible.
    app.otherElements["terminal.surface"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.typeText("echo hello from pocahontas")
    capture("14-terminal-keyboard", app)
    app.buttons["Ctrl"].tap()
    capture("15-terminal-control-key", app)
    app.buttons["Ctrl"].tap()
    XCUIDevice.shared.orientation = .landscapeLeft
    capture("16-terminal-landscape-keyboard", app)
    XCUIDevice.shared.orientation = .portrait

    UIPasteboard.general.string = "cd ~/projects/pocahontas\ngit status\ntmux attach -t agent"
    app.navigationBars.buttons["Paste"].tap()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allowPaste = springboard.buttons.matching(
      NSPredicate(format: "label IN %@", ["Allow Paste", "允许粘贴"])
    ).firstMatch
    if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
    let preview = app.navigationBars["Paste multiple lines?"]
    XCTAssertTrue(preview.waitForExistence(timeout: 10))
    capture("17-paste-preview", app)
    XCUIDevice.shared.orientation = .landscapeLeft
    capture("18-paste-preview-landscape", app)
    XCUIDevice.shared.orientation = .portrait
    preview.buttons["Paste"].tap()
    capture("19-terminal-after-paste", app)

    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(app.staticTexts["terminal.error"].waitForExistence(timeout: 10))
    capture("20-error-background-disconnect", app)
    app.buttons["Close"].tap()
    password.tap()
    password.typeText("wrong-password")
    app.buttons["connection.connect"].tap()
    XCTAssertTrue(app.staticTexts["terminal.error"].waitForExistence(timeout: 10))
    capture("21-error-authentication", app)
    XCUIDevice.shared.orientation = .landscapeLeft
    capture("22-error-authentication-landscape", app)
    XCUIDevice.shared.orientation = .portrait
    app.buttons["Close"].tap()
    replace(app.textFields["connection.port"], with: "0")
    password.tap()
    password.typeText("test-only")
    app.buttons["connection.connect"].tap()
    XCTAssertTrue(app.staticTexts["terminal.error"].waitForExistence(timeout: 10))
    capture("23-error-invalid-port", app)
  }

  @MainActor
  private func fillServer(_ app: XCUIApplication) {
    replace(app.textFields["connection.host"], with: "127.0.0.1")
    replace(app.textFields["connection.port"], with: "62224")
    replace(app.textFields["connection.username"], with: "fixture")
  }

  @MainActor
  private func replace(_ field: XCUIElement, with text: String) {
    field.tap()
    if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
    }
    field.typeText(text)
  }

  @MainActor
  private func capture(_ name: String, _ app: XCUIApplication) {
    // Let rotation, sheet and Metal frame presentation settle before the screenshot.
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    // Capture the display, not XCUIApplication's cached portrait frame after rotation.
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
