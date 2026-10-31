import XCTest

final class SlowTests: XCTestCase {
    func testWaits() async throws {
        try await Task.sleep(for: .seconds(5))
    }
}
