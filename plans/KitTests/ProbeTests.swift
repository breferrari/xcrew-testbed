import XCTest
@testable import Kit

final class ProbeTests: XCTestCase {
    func testPasses() {
        XCTAssertEqual(Kit.name, "Kit")
    }

    func testFails() {
        XCTAssertEqual(Kit.name, "Other", "the name is Kit")
    }

    func testSkipped() throws {
        throw XCTSkip("skipped on purpose")
    }
}
