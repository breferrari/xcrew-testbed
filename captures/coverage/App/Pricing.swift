/// A price in cents for a number of items, cheaper by the dozen.
func price(for items: Int) -> Int {
    // Ten percent off from twelve items.
    if items >= 12 {
        return items * 90
    }
    return items * 100
}
