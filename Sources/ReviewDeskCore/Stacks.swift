import Foundation

/// What the list shows and what folders hold: a standalone PR or a whole native stack.
public struct Item: Hashable, Identifiable, Sendable {
    public var key: String
    /// Ordered by stack position; a single PR for standalone items.
    public var pullRequests: [PullRequest]

    public var id: String { key }
    public var isStack: Bool { key.hasPrefix("stack:") }
    public var updatedAt: Date { pullRequests.map(\.updatedAt).max() ?? .distantPast }
    public var repo: String { pullRequests.first?.repo ?? "" }
    /// Highest PR number in the item, i.e. the newest.
    public var number: Int { pullRequests.map(\.number).max() ?? 0 }
}

extension PullRequest {
    /// Placement, notes and mute all attach to this key, so moving a stack moves all its PRs.
    public var itemKey: String {
        if let stack { "stack:\(repo)#\(stack.number)" } else { "pr:\(id)" }
    }
}

public enum Stacks {
    /// Groups PRs into stack items ordered by position. Items are ordered by repo, then newest PR first:
    /// a stable order, so polling never reshuffles rows under the pointer or breaks Shift-click ranges.
    public static func items(_ prs: [PullRequest]) -> [Item] {
        Dictionary(grouping: prs, by: \.itemKey)
            .map { key, members in
                Item(key: key, pullRequests: members.sorted { ($0.stackPosition ?? 0, $0.number) < ($1.stackPosition ?? 0, $1.number) })
            }
            .sorted { ($0.repo, $1.number, $0.key) < ($1.repo, $0.number, $1.key) }
    }

    /// Keys of the items the viewer wrote (any PR of a stack): the sidebar lists them under My PRs, not To Review.
    /// Pass every PR, not the state-filtered ones, so hiding a merged PR never moves its stack between sections.
    public static func viewersItemKeys(_ prs: [PullRequest]) -> Set<String> {
        Set(prs.filter(\.viewerIsAuthor).map(\.itemKey))
    }

    /// Stack members we don't have yet, so following one PR of a stack shows the whole stack.
    public static func missingMembers(of prs: [PullRequest]) -> [String] {
        let known = Set(prs.map(\.id))
        return Array(Set(prs.flatMap { $0.stack?.entries.map(\.id) ?? [] }).subtracting(known)).sorted()
    }
}

extension PullRequest {
    /// The viewer's latest review approves it: done for them, so stack-wide runs leave it alone.
    public var isApprovedByViewer: Bool { viewerReviewState == "APPROVED" }
}

extension Stacks {
    /// The stack members a stack-wide review or follow-up check works on: open, and not already approved by the viewer.
    public static func toReview(_ prs: [PullRequest]) -> [PullRequest] {
        prs.filter { $0.state == "OPEN" && !$0.isApprovedByViewer }
    }
}

extension PullRequest {
    /// Open, not the viewer's own, and waiting for them as a reviewer: their review is requested (again after
    /// reviewing, too), the author pushed since their review, or they haven't reviewed it yet.
    public func awaitsReview(by viewer: String) -> Bool {
        state == "OPEN" && !viewerIsAuthor
            && (requestedReviewers.contains(viewer) || needsReReview || viewerReviewState == nil)
    }
}

extension Stacks {
    /// Keys of the items with nothing waiting for the viewer: To Review moves them into its Reviewed group.
    /// A stack stays in To Review while any of its PRs waits. Pass every PR, as for `viewersItemKeys`.
    public static func reviewedItemKeys(_ prs: [PullRequest], viewer: (PullRequest) -> String) -> Set<String> {
        let waiting = Set(prs.filter { $0.awaitsReview(by: viewer($0)) }.map(\.itemKey))
        return Set(prs.map(\.itemKey)).subtracting(waiting)
    }
}
