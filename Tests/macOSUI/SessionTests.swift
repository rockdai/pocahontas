import AppKit
import XCTest

final class SessionTests: XCTestCase {
  @MainActor func testMultipleSessions() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    XCTAssertTrue(app.textFields["connection.host"].waitForExistence(timeout: 10))
    capture("01-new-session", app)
    fill(app.textFields["connection.host"], "127.0.0.1")
    fill(
      app.textFields["connection.port"],
      ProcessInfo.processInfo.environment["POCAHONTAS_MAC_TEST_PORT"] ?? "62225")
    fill(app.textFields["connection.username"], "fixture")
    connect(app)
    capture("02-first-session", app)
    XCTAssertFalse(app.buttons["terminal.copy"].exists)
    XCTAssertFalse(app.buttons["terminal.paste"].exists)
    let tab = app.buttons["session.select.1"]
    let surface = app.textViews["terminal.surface"]
    XCTAssertLessThan(tab.frame.minY - app.windows.firstMatch.frame.minY, 12)
    XCTAssertLessThan(surface.frame.minY - tab.frame.maxY, 20)
    XCTAssertGreaterThan(surface.frame.height, app.windows.firstMatch.frame.height - 90)
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(app.textFields["connection.host"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["session.select.1"].label.contains("Connected"))
    capture("04-add-while-connected", app)
    connect(app)
    XCTAssertTrue(app.buttons["session.select.1"].label.contains("Connected"))
    capture("06-two-sessions", app)
    app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: .control)
    XCTAssertTrue(app.buttons["session.select.1"].isSelected)
    app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [.control, .shift])
    XCTAssertTrue(app.buttons["session.select.2"].isSelected)
    app.buttons["session.select.1"].click()
    XCTAssertTrue(
      app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", "session.select.")
      ).firstMatch.waitForExistence(timeout: 5))
    capture("08-switch-to-first", app)
    app.buttons["session.close.2"].click()
    XCTAssertTrue(app.buttons["session.select.2"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["session.select.1"].label.contains("Connected"))
    capture("10-close-other-session", app)
    app.typeKey("n", modifierFlags: .command)
    XCTAssertTrue(app.textFields["connection.host"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.windows.count, 2)
    capture("13-independent-window", app)
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(app.buttons["session.select.1"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.windows.count, 1)
    // A lost transport recovers when this window becomes key again.
    app.textViews["terminal.surface"].click()
    app.textViews["terminal.surface"].typeText("__POCAHONTAS_DROP__")
    let stopped = NSPredicate(format: "NOT (label CONTAINS %@)", "Connected")
    expectation(for: stopped, evaluatedWith: app.buttons["session.select.1"])
    waitForExpectations(timeout: 10)
    app.typeKey("n", modifierFlags: .command)
    XCTAssertTrue(app.textFields["connection.host"].waitForExistence(timeout: 5))
    app.typeKey("w", modifierFlags: .command)
    let recovered = NSPredicate(format: "label CONTAINS %@", "Connected")
    expectation(for: recovered, evaluatedWith: app.buttons["session.select.1"])
    waitForExpectations(timeout: 15)
    capture("14-window-reconnected", app)
    app.buttons["session.new"].click()
    fill(app.secureTextFields["connection.password"], "wrong-password")
    app.buttons["connection.connect"].click()
    XCTAssertTrue(app.descendants(matching: .any)["terminal.error"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["session.select.1"].label.contains("Connected"))
    capture("11-independent-failure", app)
    app.buttons["session.close.3"].click()
    XCTAssertTrue(app.buttons["session.select.1"].label.contains("Connected"))
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.close."))
      .firstMatch.click()
    XCTAssertTrue(app.textFields["connection.host"].waitForExistence(timeout: 5))
  }

  @MainActor private func connect(_ app: XCUIApplication) {
    fill(app.secureTextFields["connection.password"], "pocahontas-test")
    app.buttons["connection.connect"].click()
    let trust = app.windows.firstMatch.buttons["Trust and connect"].firstMatch
    if trust.waitForExistence(timeout: 3) { trust.click() }
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
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeText(XCUIKeyboardKey.delete.rawValue)
    field.typeText(value)
  }
  @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
