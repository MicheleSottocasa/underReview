import Foundation

/// What the list shows and what folders hold: a standalone PR or a whole native stack.
public struct Item: Hashable, Identifiable, Sendable {
    public var key: String
    /// Ordered by stack position; a single PR for standalone items.
    public var pullRequests: [PullRequest]

    public var id: String { key }
    public var isStack: Bool { key.hasPrefix("stack:") }
    public var updatedAt: Date { pullRequests.map(\.updatedAt).max() ?? .distantPast }
}

extension PullRequest {
    /// Placement, notes and mute all attach to this key, so moving a stack moves all its PRs.
    public var itemKey: String {
        if let stack { "stack:\(repo)#\(stack.number)" } else { "pr:\(id)" }
    }
}

public enum Stacks {
    /// Groups PRs into stack items ordered by position; most recently updated items first.
    public static func items(_ prs: [PullRequest]) -> [Item] {
        Dictionary(grouping: prs, by: \.itemKey)
            .map { key, members in
                Item(key: key, pullRequests: members.sorted { ($0.stackPosition ?? 0, $0.number) < ($1.stackPosition ?? 0, $1.number) })
            }
            .sorted { ($0.updatedAt, $0.key) > ($1.updatedAt, $1.key) }
    }

    /// Stack members we don't have yet, so following one PR of a stack shows the whole stack.
    public static func missingMembers(of prs: [PullRequest]) -> [String] {
        let known = Set(prs.map(\.id))
        return Array(Set(prs.flatMap { $0.stack?.entries.map(\.id) ?? [] }).subtracting(known)).sorted()
    }
}
