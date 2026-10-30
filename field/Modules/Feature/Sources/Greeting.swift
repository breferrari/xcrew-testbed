public struct Greeting {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// Half tested: `hello` runs in ProbeTests, `farewell` in no test.
public extension Greeting {
    var hello: String { "Hello, \(name)" }
    var farewell: String { "Goodbye, \(name)" }
}
