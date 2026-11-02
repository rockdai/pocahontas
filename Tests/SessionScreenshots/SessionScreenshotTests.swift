import UIKit
import XCTest

final class SessionScreenshotTests: XCTestCase {
  @MainActor func testMultipleSessions() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    capture("01-new-session", app)
    fill(app.textFields["connection.host"], "127.0.0.1")
    fill(app.textFields["connection.port"], "62226")
    fill(app.textFields["connection.username"], "fixture")
    connect(app)
    capture("02-first-session", app)
    landscape("03-first-session-landscape", app)
    app.buttons["session.new"].tap()
    XCTAssertTrue(app.textFields["connection.host"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["session.select.1"].label.contains("Connected"))
    capture("04-add-while-connected", app)
    landscape("05-add-while-connected-landscape", app)
    connect(app)
    XCTAssertTrue(app.buttons["session.select.1"].label.contains("Connected"))
    capture("06-two-sessions", app)
    landscape("07-two-sessions-landscape", app)
    app.buttons["session.select.1"].tap()
    XCTAssertTrue(app.buttons["session.select.1"].isSelected)
    XCTAssertTrue(
      app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", "session.select.")
      ).firstMatch.waitForExistence(timeout: 5))
    capture("08-switch-to-first", app)
    landscape("09-switch-to-first-landscape", app)
    app.buttons["session.close.2"].tap()
    XCTAssertTrue(app.buttons["session.select.2"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["session.select.1"].label.contains("Connected"))
    capture("10-close-other-session", app)
    XCUIDevice.shared.press(.home)
    app.activate()
    let recovered = NSPredicate(format: "label CONTAINS %@", "Connected")
    expectation(for: recovered, evaluatedWith: app.buttons["session.select.1"])
    waitForExpectations(timeout: 15)
    capture("13-foreground-reconnected", app)
    app.buttons["session.new"].tap()
    fill(app.secureTextFields["connection.password"], "wrong-password")
    app.buttons["connection.connect"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["terminal.error"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["session.select.1"].label.contains("Connected"))
    capture("11-independent-failure", app)
    landscape("12-independent-failure-landscape", app)
    app.buttons["session.close.3"].tap()
    XCTAssertTrue(app.buttons["session.select.1"].label.contains("Connected"))
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.close."))
      .firstMatch.tap()
    XCTAssertTrue(app.textFields["connection.host"].waitForExistence(timeout: 5))
  }

  @MainActor private func connect(_ app: XCUIApplication) {
    fill(app.secureTextFields["connection.password"], "pocahontas-test")
    app.buttons["connection.connect"].tap()
    let trust = app.buttons["Trust and connect"]
    if trust.waitForExistence(timeout: 3) { trust.tap() }
    XCTAssertTrue(
      app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", "session.select.")
      ).firstMatch.waitForExistence(timeout: 15))
    let connected = NSPredicate(format: "label CONTAINS %@", "Connected")
    expectation(
      for: connected,
      evaluatedWith: app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", "session.select.")
      ).firstMatch)
    waitForExpectations(timeout: 15)
  }
  @MainActor private func fill(_ field: XCUIElement, _ value: String) {
    // iPadOS can present the number pad as a popover over the rest of the form.
    let dismiss = XCUIApplication().otherElements["PopoverDismissRegion"]
    if dismiss.exists { dismiss.tap() }
    XCTAssertTrue(field.waitForExistence(timeout: 5))
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
    // Orientation changes can return before UIKit finishes rotating hit-test geometry.
    RunLoop.current.run(until: Date().addingTimeInterval(0.75))
  }
  @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
