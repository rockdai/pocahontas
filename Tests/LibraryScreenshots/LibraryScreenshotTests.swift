import UIKit
import XCTest

/// Uses only the shipping UI and a disposable simulator. Fixture keys are public test data.
final class LibraryScreenshotTests: XCTestCase {
  @MainActor func testSavedConnectionsAndKeychain() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    app.buttons["library.open"].tap()
    XCTAssertTrue(app.navigationBars["Saved Connections"].waitForExistence(timeout: 10))
    capture("01-library-empty", app)
    landscape("02-library-empty-landscape", app)

    app.buttons["library.sync"].tap()
    XCTAssertTrue(app.navigationBars["iCloud Sync"].waitForExistence(timeout: 5))
    capture("03-icloud-settings", app)
    landscape("04-icloud-settings-landscape", app)
    app.navigationBars["iCloud Sync"].buttons["Done"].tap()

    app.buttons["library.add"].tap()
    XCTAssertTrue(app.textFields["saved.name"].waitForExistence(timeout: 5))
    capture("05-add-connection", app)
    fill(app.textFields["saved.name"], "Agent workstation")
    fill(app.textFields["saved.host"], "127.0.0.1")
    fill(app.textFields["saved.port"], "62224")
    fill(app.textFields["saved.username"], "fixture")
    app.textFields["saved.username"].typeText("\n")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    let remember = app.switches["saved.remember"]
    remember.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    let password = app.secureTextFields["saved.password"]
    XCTAssertTrue(password.waitForExistence(timeout: 3))
    password.tap()
    password.typeText("pocahontas-test")
    capture("06-add-connection-password", app)
    app.buttons["saved.save"].tap()
    XCTAssertTrue(app.staticTexts["Agent workstation"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Credential available · this device"].exists)
    capture("07-library-saved", app)
    landscape("08-library-saved-landscape", app)

    // A cold app launch must restore metadata AND read the credential from real Keychain.
    app.terminate()
    app.launch()
    app.buttons["library.open"].tap()
    XCTAssertTrue(app.staticTexts["Agent workstation"].waitForExistence(timeout: 5))
    app.staticTexts["Agent workstation"].tap()
    XCTAssertTrue(app.buttons["saved.connect"].waitForExistence(timeout: 5))
    capture("09-saved-connection", app)
    landscape("10-saved-connection-landscape", app)
    app.buttons["saved.connect"].tap()
    XCTAssertTrue(app.alerts["Trust this server?"].waitForExistence(timeout: 15))
    app.alerts["Trust this server?"].buttons["Trust and connect"].tap()
    XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 15))
    capture("11-saved-terminal", app)
    landscape("12-saved-terminal-landscape", app)
    app.buttons["Close"].tap()
    app.buttons["library.open"].tap()

    app.buttons["library.identities"].tap()
    XCTAssertTrue(app.navigationBars["SSH Identities"].waitForExistence(timeout: 5))
    capture("13-identities-empty", app)
    landscape("14-identities-empty-landscape", app)
    app.navigationBars["SSH Identities"].buttons["Import SSH Key"].tap()
    XCTAssertTrue(app.textFields["identity.name"].waitForExistence(timeout: 5))
    capture("15-import-identity", app)
    fill(app.textFields["identity.name"], "Development key")
    let keyURL = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "ed25519_plain", withExtension: nil))
    let key = try String(contentsOf: keyURL, encoding: .utf8)
    let editor = app.textViews["identity.key"]
    editor.tap()
    editor.typeText(key)
    capture("16-import-identity-key", app)
    app.buttons["Save Key"].tap()
    XCTAssertTrue(app.buttons["Replace Key"].waitForExistence(timeout: 10))
    capture("17-identities-saved", app)
    landscape("18-identities-saved-landscape", app)
    app.buttons["Delete Identity"].tap()
    capture("19-delete-identity-confirmation", app)
    if app.buttons["Cancel"].exists {
      app.buttons["Cancel"].tap()
    } else {
      app.navigationBars["SSH Identities"].tap()
    }
    app.buttons["Replace Key"].tap()
    XCTAssertTrue(app.textFields["identity.name"].waitForExistence(timeout: 5))
    capture("20-replace-identity", app)
  }

  @MainActor private func fill(_ field: XCUIElement, _ value: String) {
    field.tap()
    if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
    }
    field.typeText(value)
  }
  @MainActor private func landscape(_ name: String, _ app: XCUIApplication) {
    XCUIDevice.shared.orientation = .landscapeLeft
    capture(name, app)
    XCUIDevice.shared.orientation = .portrait
  }
  @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
    // XCUIApplication can retain a cached portrait crop after sheet rotation.
    // Capture the actual display, as in the terminal screenshot suite.
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
