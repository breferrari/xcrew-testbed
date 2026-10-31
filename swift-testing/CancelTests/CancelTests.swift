import Testing
@testable import Kit

@Suite struct CancelTests {
    @Test func passes() {
        #expect(Kit.name == "Kit")
    }

    @Test func cancels() throws {
        try Test.cancel("cancelled on purpose")
    }
}
