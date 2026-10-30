import XCTest

final class RepetitionTests: XCTestCase {
    func testPassesEveryRun() {
        XCTAssertTrue(true)
    }

    func testFailsEveryRun() {
        XCTFail("fails on every run")
    }

    func testFailsEveryOtherRun() throws {
        let counter = FileManager.default.temporaryDirectory.appending(path: "xcrew-testbed-repetitions")
        let runs = (Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "") ?? 0) + 1
        try String(runs).write(to: counter, atomically: true, encoding: .utf8)
        XCTAssertEqual(runs % 2, 0, "fails on every other run")
    }
}
