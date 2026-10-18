import Foundation

extension TypingCounters {
    /// The regions an event at (x, y) counts in: the row of the key nearest the point (rows by their top,
    /// `row1` the highest; lower than the fourth counts as `row4`), and `left` or `right` when that key is
    /// the first or last of its row. Empty without keys. The point itself is not kept.
    static func regions(x: Double, y: Double, keys: [PlacedKey]) -> [Region] {
        guard let index = KeyboardLayout.nearestKey(toX: x, y: y, in: keys) else { return [] }
        let key = keys[index]
        let tops = Set(keys.map(\.frame.y)).sorted()
        let row = tops.firstIndex(of: key.frame.y) ?? 0
        var regions = [Region.rows[min(row, Region.rows.count - 1)]]
        let rowKeys = keys.filter { $0.frame.y == key.frame.y }
        if rowKeys.count > 1 {
            if key.frame.x == rowKeys.map(\.frame.x).min() { regions.append(.left) }
            if key.frame.x == rowKeys.map(\.frame.x).max() { regions.append(.right) }
        }
        return regions
    }
}
