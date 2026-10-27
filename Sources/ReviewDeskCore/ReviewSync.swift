import Foundation

/// A local inline comment. It becomes part of the viewer's pending review only on explicit save.
public struct Draft: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var prID: String
    public var anchor: Anchor
    public var body: String
    /// Head commit the draft was written against.
    public var commitOID: String
    /// Comment node id inside the pending review, once saved to GitHub.
    public var remoteID: String?
    /// Body as last saved to GitHub, to detect local edits.
    public var syncedBody: String?
    /// The file changed after a push: the user must re-place the draft before syncing.
    public var isStale = false
    /// First line of a multi-line comment (same side as the anchor), e.g. a suggested change spanning lines.
    public var startLine: Int?

    public init(prID: String, anchor: Anchor, body: String, commitOID: String) {
        self.prID = prID
        self.anchor = anchor
        self.body = body
        self.commitOID = commitOID
    }

    public var needsSync: Bool { remoteID == nil || syncedBody != body }
}

public enum ReviewEvent: String, CaseIterable, Sendable {
    case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES"

    /// What the viewer may submit: GitHub refuses an approval or a change request on your own pull request.
    public static func allowed(for pr: PullRequest) -> [ReviewEvent] {
        pr.viewerIsAuthor ? [.comment] : allCases
    }
}

public enum ReviewSyncError: Error, LocalizedError, Equatable {
    case staleDrafts(Int)

    public var errorDescription: String? {
        switch self {
        case .staleDrafts(let count): "\(count) draft(s) are outdated after a new push. Re-place or delete them first."
        }
    }
}

/// Writes go through GraphQL: REST can't add comments to an existing pending review.
/// GitHub has no idempotency keys, so after a timeout we re-read state before retrying.
public struct ReviewSync: Sendable {
    public let github: GitHub

    public init(github: GitHub) { self.github = github }

    public func pendingReview(prID: String) async throws -> PendingReview? {
        try await github.pendingReview(prID: prID)
    }

    /// Marks drafts stale when their file changed since they were written; otherwise moves them to the new head.
    public func refreshStaleness(_ drafts: [Draft], pr: PullRequest) async -> [Draft] {
        var changedByBase: [String: Set<String>?] = [:]
        var result: [Draft] = []
        for var draft in drafts {
            if draft.commitOID != pr.headRefOid, !draft.isStale {
                if changedByBase[draft.commitOID] == nil {
                    // A force-push can make the old commit unreachable: treat as changed.
                    changedByBase[draft.commitOID] = try? await github.changedPaths(repo: pr.repo, from: draft.commitOID, to: pr.headRefOid)
                }
                if let changed = changedByBase[draft.commitOID] ?? nil, !changed.contains(draft.anchor.path) {
                    draft.commitOID = pr.headRefOid
                } else {
                    draft.isStale = true
                }
            }
            result.append(draft)
        }
        return result
    }

    /// Adds or updates the given drafts in the viewer's pending review, creating it if needed.
    /// Comments made outside the app are never touched.
    public func save(_ drafts: [Draft], pr: PullRequest) async throws -> [Draft] {
        let stale = drafts.filter(\.isStale).count
        guard stale == 0 else { throw ReviewSyncError.staleDrafts(stale) }
        var pending = try await pendingReview(prID: pr.id)
        let reviewID: String
        if let pending {
            reviewID = pending.id
        } else {
            reviewID = try await idempotent {
                try await self.createReview(pr: pr, event: nil, body: nil)
            } reconcile: {
                try await self.pendingReview(prID: pr.id)?.id
            }
            pending = PendingReview(id: reviewID, commitOID: pr.headRefOid, comments: [])
        }

        var result: [Draft] = []
        for var draft in drafts {
            let remote = pending?.comments.first { $0.id == draft.remoteID }
            if remote == nil {
                draft.remoteID = nil // deleted on github.com, or the review was submitted
            }
            if draft.remoteID == nil, let match = pending?.comments.first(where: { Self.matches($0, draft) }) {
                draft.remoteID = match.id
            } else if draft.remoteID == nil {
                let current = draft
                draft.remoteID = try await idempotent {
                    try await self.addThread(reviewID: reviewID, draft: current)
                } reconcile: {
                    try await self.pendingReview(prID: pr.id)?.comments.first { Self.matches($0, current) }?.id
                }
            } else if draft.syncedBody != draft.body {
                // Update is idempotent: retrying sets the same body.
                try await updateComment(id: draft.remoteID!, body: draft.body)
            }
            draft.syncedBody = draft.body
            result.append(draft)
        }
        return result
    }

    /// Removes a saved draft from the pending review. Local-only drafts need no call.
    public func delete(_ draft: Draft) async throws {
        guard let id = draft.remoteID else { return }
        do {
            try await github.graphql("mutation($id: ID!) { deletePullRequestReviewComment(input: {id: $id}) { clientMutationId } }", ["id": id])
        } catch GitHubError.graphQL {
            // Already gone (deleted on github.com or review submitted): nothing to do.
        }
    }

    /// Deletes the viewer's whole pending review, like GitHub's Cancel review: comments added to it outside the app
    /// go too. No pending review needs no call.
    public func discard(pr: PullRequest) async throws {
        guard let pending = try await pendingReview(prID: pr.id) else { return }
        do {
            try await github.graphql("mutation($id: ID!) { deletePullRequestReview(input: {pullRequestReviewId: $id}) { clientMutationId } }",
                                     ["id": pending.id])
        } catch let error as GitHubError {
            // Already gone (submitted or deleted on github.com meanwhile): nothing to discard. Any other refusal
            // leaves it in place, and must fail so the local drafts aren't dropped as if it were gone.
            guard case .graphQL = error, try await pendingReview(prID: pr.id)?.id != pending.id else { throw error }
        }
    }

    /// Submits the pending review, or creates a body-only review when none is pending.
    public func publish(pr: PullRequest, event: ReviewEvent, body: String, viewer: String) async throws {
        if let pending = try await pendingReview(prID: pr.id) {
            _ = try await idempotent {
                try await self.github.graphql("""
                mutation($id: ID!, $event: PullRequestReviewEvent!, $body: String) {
                  submitPullRequestReview(input: {pullRequestReviewId: $id, event: $event, body: $body}) { pullRequestReview { id } }
                }
                """, ["id": pending.id, "event": event.rawValue, "body": body])
                return pending.id
            } reconcile: {
                try await self.pendingReview(prID: pr.id)?.id == pending.id ? nil : pending.id
            }
        } else {
            let since = Date()
            _ = try await idempotent {
                try await self.createReview(pr: pr, event: event, body: body)
            } reconcile: {
                try await self.latestReview(prID: pr.id, by: viewer, body: body, since: since)
            }
        }
    }

    /// Replies to an inline thread immediately.
    public func reply(threadID: String, body: String, viewer: String) async throws {
        let since = Date()
        _ = try await idempotent {
            let data = try await self.github.graphql("""
            mutation($thread: ID!, $body: String!) {
              addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) { comment { id } }
            }
            """, ["thread": threadID, "body": body])
            return ((data["addPullRequestReviewThreadReply"] as? [String: Any])?["comment"] as? [String: Any])?["id"] as? String ?? ""
        } reconcile: {
            let data = try await self.github.graphql("""
            query($id: ID!) { node(id: $id) { ... on PullRequestReviewThread { comments(last: 10) { nodes { id author { login } body createdAt } } } } }
            """, ["id": threadID])
            return GitHub.nodes((data["node"] as? [String: Any])?["comments"]).map(GitHub.decodeComment)
                .first { $0.author == viewer && $0.body == body && $0.createdAt >= since.addingTimeInterval(-60) }?.id
        }
    }

    // MARK: - Helpers

    /// Runs a write; on timeout, asks GitHub whether it landed before trying once more.
    func idempotent(_ write: @Sendable () async throws -> String, reconcile: @Sendable () async throws -> String?) async throws -> String {
        do {
            return try await write()
        } catch CommandError.timedOut {
            if let landed = try await reconcile() { return landed }
            return try await write()
        }
    }

    static func matches(_ comment: PendingComment, _ draft: Draft) -> Bool {
        comment.path == draft.anchor.path && comment.line == draft.anchor.line && comment.body == draft.body
    }

    func createReview(pr: PullRequest, event: ReviewEvent?, body: String?) async throws -> String {
        var variables: [String: any Sendable] = ["pr": pr.id, "oid": pr.headRefOid]
        if let event { variables["event"] = event.rawValue }
        if let body { variables["body"] = body }
        let data = try await github.graphql("""
        mutation($pr: ID!, $oid: GitObjectID, $event: PullRequestReviewEvent, $body: String) {
          addPullRequestReview(input: {pullRequestId: $pr, commitOID: $oid, event: $event, body: $body}) { pullRequestReview { id } }
        }
        """, variables)
        return ((data["addPullRequestReview"] as? [String: Any])?["pullRequestReview"] as? [String: Any])?["id"] as? String ?? ""
    }

    func addThread(reviewID: String, draft: Draft) async throws -> String {
        let data = try await github.graphql("""
        mutation($review: ID!, $path: String!, $line: Int!, $side: DiffSide!, $body: String!, $startLine: Int, $startSide: DiffSide) {
          addPullRequestReviewThread(input: {pullRequestReviewId: $review, path: $path, line: $line, side: $side, body: $body,
                                             startLine: $startLine, startSide: $startSide}) {
            thread { comments(first: 1) { nodes { id } } }
          }
        }
        """, variables(draft, review: reviewID))
        let thread = (data["addPullRequestReviewThread"] as? [String: Any])?["thread"] as? [String: Any]
        return GitHub.nodes(thread?["comments"]).first?["id"] as? String ?? ""
    }

    /// A multi-line comment also sends where it starts; GitHub takes a missing start as a single line.
    func variables(_ draft: Draft, review: String) -> [String: any Sendable] {
        var variables: [String: any Sendable] = ["review": review, "path": draft.anchor.path, "line": draft.anchor.line,
                                                 "side": draft.anchor.side.rawValue, "body": draft.body]
        if let start = draft.startLine, start < draft.anchor.line {
            variables["startLine"] = start
            variables["startSide"] = draft.anchor.side.rawValue
        }
        return variables
    }

    func updateComment(id: String, body: String) async throws {
        try await github.graphql("""
        mutation($id: ID!, $body: String!) {
          updatePullRequestReviewComment(input: {pullRequestReviewCommentId: $id, body: $body}) { pullRequestReviewComment { id } }
        }
        """, ["id": id, "body": body])
    }

    func latestReview(prID: String, by viewer: String, body: String, since: Date) async throws -> String? {
        let data = try await github.graphql("""
        query($id: ID!, $author: String!) { node(id: $id) { ... on PullRequest { reviews(last: 5, author: $author) { nodes { id body state submittedAt } } } } }
        """, ["id": prID, "author": viewer])
        return GitHub.nodes((data["node"] as? [String: Any])?["reviews"]).first {
            $0["body"] as? String == body && $0["state"] as? String != "PENDING"
                && (GitHub.date($0["submittedAt"]) ?? .distantPast) >= since.addingTimeInterval(-60)
        }?["id"] as? String
    }
}
