import XCTest

final class AccountUITests: XCTestCase {
  @MainActor func testRegistrationAndPersistence() throws {
    let address = ProcessInfo.processInfo.environment["POCAHONTAS_ACCOUNT_TEST_URL"] ?? ""
    guard address.hasPrefix("http://127.0.0.1:") else { throw XCTSkip("Requires the disposable account fixture") }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark"]
    app.launch()
    openAccount(app)
    capture("01-sign-in", app)
    let email = "demo-\(UUID().uuidString.prefix(6).lowercased())@example.com"
    fill(app.textFields["account.email"], email)
    fill(app.secureTextFields["account.password"], "Pocahontas UI test password")
    capture("02-sign-in-filled", app)
    select("Register", app)
    capture("03-register", app)
    fill(app.secureTextFields["account.password"], "Pocahontas UI test password")
    fill(app.secureTextFields["account.confirm"], "Pocahontas UI test password")
    tap(app.buttons["account.send-code"])
    XCTAssertTrue(app.staticTexts["account.notice"].waitForExistence(timeout: 10))
    let data = try Data(contentsOf: URL(string: address + "/test/code?email=" + email)!)
    let response = try JSONDecoder().decode(Code.self, from: data)
    fill(app.textFields["account.code"], response.code)
    capture("04-register-code", app)
    tap(app.buttons["account.submit"])
    XCTAssertTrue(app.buttons["account.submit"].waitForNonExistence(timeout: 15))
    XCTAssertTrue(app.buttons["library.sync"].waitForExistence(timeout: 15))
    tap(app.buttons["library.sync"])
    reveal(app.buttons["Sign Out"])
    XCTAssertTrue(app.buttons["Sign Out"].waitForExistence(timeout: 10))
    capture("05-account-synced", app)
    // Cold launch verifies that the real platform Keychain restores the session.
    app.terminate()
    app.launch()
    openAccount(app)
    XCTAssertEqual(app.descendants(matching: .any)["account.email-value"].firstMatch.value as? String, email)
    reveal(app.buttons["Sign Out"])
    XCTAssertTrue(app.buttons["Sign Out"].waitForExistence(timeout: 10))
    capture("06-account-restored", app)
    tap(app.buttons["Sign Out"])
    XCTAssertTrue(app.buttons["Sign Out"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.buttons["library.sync"].waitForExistence(timeout: 10))
    tap(app.buttons["library.sync"])
    fill(app.textFields["account.email"], email)
    fill(app.secureTextFields["account.password"], "Pocahontas UI test password")
    tap(app.buttons["account.submit"])
    XCTAssertTrue(app.buttons["account.submit"].waitForNonExistence(timeout: 15))
    tap(app.buttons["library.sync"])
    reveal(app.buttons["Sign Out"])
    XCTAssertTrue(app.buttons["Sign Out"].waitForExistence(timeout: 10))
    tap(app.buttons["Sign Out"])
    XCTAssertTrue(app.buttons["Sign Out"].waitForNonExistence(timeout: 10))
  }
  @MainActor func testResetConfirmationScreens() throws {
    guard (ProcessInfo.processInfo.environment["POCAHONTAS_ACCOUNT_TEST_URL"] ?? "").hasPrefix("http://127.0.0.1:")
      else { throw XCTSkip("Requires the disposable account fixture") }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark"]
    app.launch()
    openAccount(app)
    select("Reset Password", app)
    capture("07-reset-password", app)
    fill(app.textFields["account.email"], "demo-reset@example.com")
    fill(app.secureTextFields["account.password"], "Pocahontas reset password")
    fill(app.secureTextFields["account.confirm"], "Pocahontas reset password")
    tap(app.buttons["account.send-code"])
    XCTAssertTrue(app.staticTexts["account.notice"].waitForExistence(timeout: 10))
    // Exercise the destructive confirmation, then cancel; actual reset is covered by the API integration test.
    fill(app.textFields["account.code"], "00000000")
    capture("08-reset-filled", app)
    reveal(app.buttons["account.submit"])
    XCTAssertTrue(app.buttons["account.submit"].isEnabled)
    tap(app.buttons["account.submit"])
    XCTAssertTrue(app.buttons["Clear Data and Reset Password"].waitForExistence(timeout: 5))
    capture("09-reset-confirmation", app)
    if app.buttons["Cancel"].exists { tap(app.buttons["Cancel"].firstMatch) }
    else {
      #if os(macOS)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
      #else
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
      #endif
    }
    XCTAssertTrue(app.buttons["Clear Data and Reset Password"].waitForNonExistence(timeout: 5))
  }
  private struct Code: Decodable { var code: String }
  @MainActor private func openAccount(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["library.open"].waitForExistence(timeout: 10))
    tap(app.buttons["library.open"])
    XCTAssertTrue(app.buttons["library.sync"].waitForExistence(timeout: 5))
    tap(app.buttons["library.sync"])
  }
  @MainActor private func select(_ title: String, _ app: XCUIApplication) {
    #if os(macOS)
      tap(app.radioButtons[title])
    #else
      tap(app.buttons[title].firstMatch)
    #endif
  }
  @MainActor private func tap(_ element: XCUIElement) {
    #if os(macOS)
      element.click()
    #else
      reveal(element)
      element.tap()
    #endif
  }
  @MainActor private func reveal(_ element: XCUIElement) {
    #if os(iOS)
      let app = XCUIApplication()
      let form = app.descendants(matching: .any)["account.form"].firstMatch
      guard form.exists else { return }
      for _ in 0..<8 {
        let navigation = app.navigationBars["Account & Sync"].frame
        let top = max(form.frame.minY, navigation.maxY) + 8
        let bottom = form.frame.maxY - 16
        var down = false
        if element.exists {
          let frame = element.frame
          if element.isHittable && frame.minY >= top && frame.maxY <= bottom { return }
          down = frame.minY < top
        }
        let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.5 : 0.7))
        let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
      }
      XCTFail("Could not reveal \(element)")
    #endif
  }
  @MainActor private func fill(_ element: XCUIElement, _ value: String) {
    tap(element)
    #if os(iOS)
      if element.elementType == .secureTextField {
        for surface in [XCUIApplication(), XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
          let suggestion = surface.buttons.matching(NSPredicate(format:
            "label CONTAINS[c] 'Strong Password' OR label CONTAINS '强密码'")).firstMatch
          if suggestion.exists {
            let close = surface.buttons.matching(NSPredicate(format:
              "label == 'Close' OR label CONTAINS '关闭'")).firstMatch
            XCTAssertTrue(close.exists, surface.debugDescription)
            close.tap()
            XCTAssertTrue(suggestion.waitForNonExistence(timeout: 5))
            break
          }
        }
      }
    #endif
    if let old = element.value as? String, !old.isEmpty, old != element.placeholderValue {
      element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
    }
    element.typeText(value)
    #if os(iOS)
      element.typeText("\n")
    #endif
  }
  @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
    #if os(macOS)
      let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    #else
      let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    #endif
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
