import Foundation

/// What we remember about a PR between polls. Persisted, so restarts and sleep don't replay events.
public struct Snapshot: Codable, Hashable, Sendable {
    public var headRefOid: String
    public var state: String
    public var commentCount: Int
    public var reviewCount: Int
    public var threadCommentCount: Int
    public var reviewRequested: Bool

    public init(_ pr: PullRequest, viewer: String) {
        headRefOid = pr.headRefOid
        state = pr.state
        commentCount = pr.commentCount
        reviewCount = pr.reviewCount
        threadCommentCount = pr.threadCommentCount
        reviewRequested = pr.requestedReviewers.contains(viewer)
    }
}

public enum UpdateKind: Hashable, Sendable {
    case newCommits
    case stateChanged(String)
    case newComments(Int)
    case newReviews(Int)
    case newReplies(Int)
    case reviewRequested

    public var text: String {
        switch self {
        case .newCommits: "New commits pushed"
        case .stateChanged(let state): "Now \(state.lowercased())"
        case .newComments(let n): n == 1 ? "1 new comment" : "\(n) new comments"
        case .newReviews(let n): n == 1 ? "1 new review" : "\(n) new reviews"
        case .newReplies(let n): n == 1 ? "1 new reply in threads" : "\(n) new replies in threads"
        case .reviewRequested: "Your review was requested"
        }
    }
}

public enum Updates {
    /// Changes between two snapshots. No previous snapshot means first sight: no historical events.
    public static func kinds(old: Snapshot?, new: Snapshot) -> [UpdateKind] {
        guard let old else { return [] }
        var kinds: [UpdateKind] = []
        if new.headRefOid != old.headRefOid { kinds.append(.newCommits) }
        if new.state != old.state { kinds.append(.stateChanged(new.state)) }
        if new.commentCount > old.commentCount { kinds.append(.newComments(new.commentCount - old.commentCount)) }
        if new.reviewCount > old.reviewCount { kinds.append(.newReviews(new.reviewCount - old.reviewCount)) }
        if new.threadCommentCount > old.threadCommentCount { kinds.append(.newReplies(new.threadCommentCount - old.threadCommentCount)) }
        if new.reviewRequested, !old.reviewRequested { kinds.append(.reviewRequested) }
        return kinds
    }

    /// Advances the checkpoints and returns new events grouped per PR id.
    /// After an offline gap this naturally collapses everything missed into one group per PR.
    public static func advance(_ checkpoints: inout [String: Snapshot], with prs: [PullRequest], viewer: String) -> [String: [UpdateKind]] {
        var events: [String: [UpdateKind]] = [:]
        for pr in prs {
            let snapshot = Snapshot(pr, viewer: viewer)
            let kinds = kinds(old: checkpoints[pr.id], new: snapshot)
            if !kinds.isEmpty { events[pr.id] = kinds }
            checkpoints[pr.id] = snapshot
        }
        return events
    }

    /// PR ids whose cached data is missing or older than GitHub's last update: only these get the full (costly) fetch.
    public static func changed(_ stamps: [String: Date], cached: [String: PullRequest]) -> [String] {
        stamps.filter { cached[$0.key]?.updatedAt != $0.value }.map(\.key).sorted()
    }

    public static let defaultForeground = 180, defaultBackground = 600
    /// Shorter polls risk GitHub's hourly GraphQL limit again.
    public static let minimumInterval = 60

    /// Poll interval (180 s in foreground and 600 s in background by default), doubling per consecutive
    /// failure up to 30 min.
    public static func interval(foreground: Bool, failures: Int,
                                foregroundSeconds: Int = defaultForeground, backgroundSeconds: Int = defaultBackground) -> Duration {
        let base = max(minimumInterval, foreground ? foregroundSeconds : backgroundSeconds)
        return .seconds(min(base << min(failures, 4), max(1800, base)))
    }
}
