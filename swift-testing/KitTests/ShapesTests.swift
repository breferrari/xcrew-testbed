import Testing
@testable import Kit

@Suite struct ShapesTests {
    @Test func passes() {
        #expect(Kit.name == "Kit")
    }

    @Test func fails() {
        #expect(Kit.name == "Other", "the name is Kit")
    }

    @Test(.disabled("skipped on purpose")) func skipped() {}

    @Test func knownIssue() {
        withKnownIssue("a known issue") {
            #expect(Kit.name == "Other")
        }
    }

    @Test(arguments: [1, 2, 3]) func parameterised(value: Int) {
        #expect(value > 0)
    }

    @Test func waits() async throws {
        try await Task.sleep(for: .seconds(5))
    }
}
