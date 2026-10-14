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

    /// Where the key area control stands: on the selected area when the cursor is on that area's row, otherwise just
    /// before the cursor's row. `rows` holds each area's diff row (nil when not in the diff) and can be shorter than
    /// the areas, e.g. empty before the diff is rendered, so the selected one is looked up safely.
    public static func areaPosition(cursor: Int?, selected: Int?, rows: [Int?], count: Int) -> Int? {
        guard let cursor else { return nil }
        let selectedRow = selected.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
        return position(row: cursor, item: selectedRow == cursor ? selected : nil, count: count)
    }

    /// The row and item of a position made by `position(row:item:count:)` with an item.
    public static func item(at position: Int, count: Int) -> (row: Int, item: Int) {
        (position / (count + 1), position % (count + 1) - 1)
    }
}
