import Foundation
import Testing
@testable import Kit

@Suite struct Outer {
    @Suite struct Inner {
        @Test func fails() {
            #expect(Kit.name == "Other", "the name is Kit")
        }

        @Test func passes() {
            #expect(Kit.name == "Kit")
        }

        @Test func flaky() throws {
            let counter = FileManager.default.temporaryDirectory.appending(path: "nested-flaky-count")
            let run = (Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "") ?? 0) + 1
            try String(run).write(to: counter, atomically: true, encoding: .utf8)
            #expect(run % 2 == 0, "run \(run) is odd")
        }

        @Test func attaches() throws {
            let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="))
            Attachment.record(png, named: "screen.png")
            #expect(Kit.name == "Other", "the screen shows Kit")
        }

        @Test("Adds numbers") func addsNumbers() {
            #expect(1 + 1 == 3, "one and one")
        }
    }
}

@Suite struct Inner {
    @Test func passes() {
        #expect(Kit.name == "Kit")
    }
}

@Suite struct Arithmetic {
    @Test("Subtracts numbers") func subtractsNumbers() {
        #expect(2 - 1 == 1)
    }
}
