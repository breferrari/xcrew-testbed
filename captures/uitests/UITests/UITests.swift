import XCTest

@MainActor
final class UITests: XCTestCase {
    func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLAN"] = ProcessInfo.processInfo.environment["PLAN"]
        app.launch()
        return app
    }

    /// No element has this identifier.
    func testMissingElement() {
        launch().buttons["checkout"].tap()
    }

    /// The title once read "Hello"; it reads "Welcome" now.
    func testRenamedLabel() {
        XCTAssertTrue(launch().staticTexts["Hello"].waitForExistence(timeout: 2))
    }

    /// Both taps pass; the assertion after them fails.
    func testFailsAfterTaps() {
        let app = launch()
        app.buttons["continue"].tap()
        app.buttons["continue"].tap()
        XCTAssertEqual(app.staticTexts["title"].label, "Welcome")
    }

    /// Passes under the test plan's "Plan A" and fails under "Plan B".
    func testPlanA() {
        XCTAssertTrue(launch().staticTexts["Plan A"].waitForExistence(timeout: 2))
    }

    func testPasses() {
        XCTAssertTrue(launch().buttons["continue"].exists)
    }
}
