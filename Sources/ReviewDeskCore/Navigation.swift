import Foundation

/// Previous/next steps through positions: files in list order, or rows of a diff.
public enum Navigation {
    /// The first position after `current` going forward, or the last one before it going back. Without a current
    /// position it's the first (or last) one. Nil at either end, so the control can be disabled there.
    public static func step(_ positions: [Int], from current: Int?, forward: Bool) -> Int? {
        let sorted = Set(positions).sorted()
        guard let current else { return forward ? sorted.first : sorted.last }
        return forward ? sorted.first { $0 > current } : sorted.last { $0 < current }
    }

    /// A position for item `item` (of `count`) on diff row `row`, so items sharing a row (key areas that start on the
    /// same line) stay separate steps, in item order. Without an item it's the spot just before the row's items.
    public static func position(row: Int, item: Int?, count: Int) -> Int {
        row * (count + 1) + (item.map { $0 + 1 } ?? 0)
    }

    /// The row and item of a position made by `position(row:item:count:)` with an item.
    public static func item(at position: Int, count: Int) -> (row: Int, item: Int) {
        (position / (count + 1), position % (count + 1) - 1)
    }
}
