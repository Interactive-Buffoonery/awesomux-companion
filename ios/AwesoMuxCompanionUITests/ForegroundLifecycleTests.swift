import XCTest

@MainActor
final class ForegroundLifecycleTests: XCTestCase {
    func testManagedQuestionSurvivesBackgroundAndResume() throws {
        let app = XCUIApplication()
        app.launch()
        let session = app.buttons["session-row"]
        guard session.waitForExistence(timeout: 10) else {
            throw XCTSkip("Requires an injected disposable managed bridge configuration.")
        }
        session.tap()
        let option = app.buttons["option-ALPHA"]
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        XCTAssertTrue(option.isEnabled)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        XCTAssertTrue(option.isEnabled)
        // Answer remains a deliberate action, never sent by lifecycle changes.
        XCTAssertFalse(app.staticTexts["Bridge received ALPHA"].exists)
    }
}
