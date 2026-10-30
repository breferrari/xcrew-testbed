import Kit

public var featureFlags: [String] = []

public func later(_ box: Box) {
    Task.detached {
        box.value += 1
    }
}
