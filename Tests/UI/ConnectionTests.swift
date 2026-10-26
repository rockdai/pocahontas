import XCTest

final class ConnectionTests: XCTestCase {
  @MainActor
  func testConnectToSSHAndRejectWrongPassword() throws {
    let app = XCUIApplication()
    app.launch()
    let host = app.textFields["connection.host"]
    XCTAssertTrue(host.waitForExistence(timeout: 10))
    replace(host, with: "127.0.0.1")
    replace(app.textFields["connection.port"], with: "62223")
    replace(app.textFields["connection.username"], with: "fixture")
    let password = app.secureTextFields["connection.password"]
    password.tap()
    password.typeText("pocahontas-test")
    app.buttons["connection.connect"].tap()
    let trust = app.alerts.buttons["Trust and connect"]
    if trust.waitForExistence(timeout: 5) { trust.tap() }
    let connected = app.staticTexts["Connected"]
    XCTAssertTrue(connected.waitForExistence(timeout: 20))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "SSH terminal connected"
    shot.lifetime = .keepAlways
    add(shot)
    app.buttons["Close"].tap()
    XCTAssertTrue(password.waitForExistence(timeout: 5))
    password.tap()
    password.typeText("wrong-password")
    app.buttons["connection.connect"].tap()
    XCTAssertTrue(app.staticTexts["terminal.error"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.staticTexts["Connected"].exists)
  }

  @MainActor
  private func replace(_ field: XCUIElement, with text: String) {
    field.tap()
    if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
    }
    field.typeText(text)
  }
}
