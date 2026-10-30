import Foundation
import XCTest
@testable import Feature

final class ProbeTests: XCTestCase {
    func testPasses() {
        XCTAssertEqual(Greeting(name: "Ada").hello, "Hello, Ada")
    }

    func testFails() {
        XCTAssertEqual(Greeting(name: "Ada").hello, "Hi, Ada")
    }

    /// Fails on every other run, counted in a file that outlives each process.
    func testFlaky() throws {
        let counter = FileManager.default.temporaryDirectory.appending(path: "field-flaky-count")
        let run = (Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "") ?? 0) + 1
        try String(run).write(to: counter, atomically: true, encoding: .utf8)
        XCTAssertEqual(run % 2, 0, "run \(run) is odd")
    }

    func testSkipped() throws {
        throw XCTSkip("waits for the farewell screen")
    }

    func testExpectedFailure() {
        XCTExpectFailure("the farewell wording isn't settled")
        XCTAssertEqual(Greeting(name: "Ada").farewell, "Bye, Ada")
    }
}

final class CrashTests: XCTestCase {
    func testOutOfRange() {
        let items: [Int] = []
        _ = items[1]
    }
}
