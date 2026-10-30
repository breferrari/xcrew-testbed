public var sharedCount = 0

public final class Box {
    public var value = 0
    public init() {}
}

public struct Holder: Sendable {
    public let box: Box
}

public func capture(_ box: Box) {
    Task.detached {
        print(box.value)
    }
}

public actor Store {
    public init() {}
    public func keep(_ box: Box) {}
}

public func hand(_ box: Box, to store: Store) async {
    await store.keep(box)
    box.value = 1
}

@MainActor public final class Screen {
    public init() {}
    public func draw() {}
}

public func leftover() {
    let unused = 1
}
