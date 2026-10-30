import XCTest

@MainActor
final class AppUITests: XCTestCase {
    func testGreets() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["greeting"].waitForExistence(timeout: 5))
    }
}
