import XCTest
@testable import App

final class PricingTests: XCTestCase {
    func testAFewItemsPayFullPrice() {
        XCTAssertEqual(price(for: 2), 200)
    }
}
