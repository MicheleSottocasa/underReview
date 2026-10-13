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
}
