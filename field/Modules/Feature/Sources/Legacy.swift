/// Compiles with a warning: `unused` is never read.
public func legacyCount() -> Int {
    let unused = 1
    return 2
}
