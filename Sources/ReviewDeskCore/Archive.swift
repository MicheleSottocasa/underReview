import Foundation

/// Local-only: items the user moved to the sidebar's Archive by hand, and items they took out of it. Merged or closed
/// items also age into it (`Item.isAged`). Archived items are still polled and still notify.
public struct PRArchive: Codable, Sendable, Equatable {
    /// What an item's pull requests looked like when it was archived: a push or a new review request brings it back.
    public struct Mark: Codable, Hashable, Sendable {
        /// PR node id → head commit.
        public var heads: [String: String]
        /// PRs whose review was requested from the viewer.
        public var requested: Set<String>
    }

    /// item key → its state when the user archived it.
    public var manual: [String: Mark] = [:]
    /// item keys the user unarchived after they aged in: ageing leaves them alone.
    /// ponytail: kept until Stop Monitoring or archiving again; prune with the PR list if the file grows.
    public var kept: Set<String> = []

    public init() {}

    /// Keys of the items the sidebar shows in an Archive group. Pass every PR, as for `Stacks.viewersItemKeys`.
    public func itemKeys(_ prs: [PullRequest], now: Date, afterDays days: Int, viewer: (PullRequest) -> String) -> Set<String> {
        Set(Stacks.items(prs).filter { contains($0, now: now, afterDays: days, viewer: viewer) }.map(\.key))
    }

    public func contains(_ item: Item, now: Date, afterDays days: Int, viewer: (PullRequest) -> String) -> Bool {
        if kept.contains(item.key) { return false }
        if let mark = manual[item.key], !Self.woke(item, since: mark, viewer: viewer) { return true }
        return item.isAged(now: now, afterDays: days)
    }

    /// An open PR of the item has a new head, is new to the stack, or newly asks the viewer for a review.
    static func woke(_ item: Item, since mark: Mark, viewer: (PullRequest) -> String) -> Bool {
        item.pullRequests.contains { pr in
            pr.state == "OPEN" && (mark.heads[pr.id] != pr.headRefOid
                || pr.requestedReviewers.contains(viewer(pr)) && !mark.requested.contains(pr.id))
        }
    }

    public mutating func archive(_ item: Item, viewer: (PullRequest) -> String) {
        kept.remove(item.key)
        manual[item.key] = Mark(
            heads: Dictionary(item.pullRequests.map { ($0.id, $0.headRefOid) }) { a, _ in a },
            requested: Set(item.pullRequests.filter { $0.requestedReviewers.contains(viewer($0)) }.map(\.id)))
    }

    /// Takes the item out, and keeps it out of ageing when it has aged already.
    public mutating func unarchive(_ item: Item, now: Date, afterDays days: Int) {
        manual[item.key] = nil
        if item.isAged(now: now, afterDays: days) { kept.insert(item.key) }
    }

    /// After a refresh: drops the marks of items that woke up, so they stay out until archived again, and forgets
    /// review requests that ended, so asking again later wakes the item too.
    public mutating func update(_ prs: [PullRequest], viewer: (PullRequest) -> String) {
        for item in Stacks.items(prs) {
            guard var mark = manual[item.key] else { continue }
            if Self.woke(item, since: mark, viewer: viewer) {
                manual[item.key] = nil
            } else {
                mark.requested = mark.requested.filter { id in item.pullRequests.contains { $0.id == id && $0.requestedReviewers.contains(viewer($0)) } }
                manual[item.key] = mark
            }
        }
    }

    /// Stop Monitoring forgets the items here too.
    public mutating func forget(_ keys: Set<String>) {
        for key in keys { manual[key] = nil }
        kept.subtract(keys)
    }
}
