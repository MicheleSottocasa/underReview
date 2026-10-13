import Foundation

// MARK: - Models

public struct PRRef: Hashable, Sendable {
    public var owner: String
    public var repo: String
    public var number: Int

    /// Accepts `https://github.com/o/r/pull/1` (with optional trailing path) or `o/r#1`.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.host == "github.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else { return nil }
            (owner, repo, self.number) = (parts[0], parts[1], number)
        } else {
            let pieces = trimmed.split(separator: "#")
            let names = pieces.first?.split(separator: "/") ?? []
            guard pieces.count == 2, names.count == 2, let number = Int(pieces[1]) else { return nil }
            (owner, repo, self.number) = (String(names[0]), String(names[1]), number)
        }
    }

    public init(nameWithOwner: String, number: Int) {
        let parts = nameWithOwner.split(separator: "/")
        (owner, repo, self.number) = (String(parts.first ?? ""), String(parts.last ?? ""), number)
    }

    public var nameWithOwner: String { "\(owner)/\(repo)" }
}

public struct StackInfo: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var position: Int
        public var id: String
        public var number: Int
    }

    public var number: Int
    /// Sorted by position: 1 is closest to the base branch.
    public var entries: [Entry]

    /// The entries just below (closer to the base) and just above `id`, for stepping through the stack.
    public func neighbors(of id: String) -> (below: Entry?, above: Entry?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
        return (index > 0 ? entries[index - 1] : nil, index + 1 < entries.count ? entries[index + 1] : nil)
    }
}

public struct PullRequest: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var number: Int
    public var title: String
    public var url: String
    public var state: String
    public var isDraft: Bool
    public var updatedAt: Date
    public var headRefOid: String
    public var headRefName: String
    public var baseRefName: String
    public var author: String
    public var repo: String
    public var commentCount: Int
    public var reviewCount: Int
    /// Sum of comments across inline threads: grows on every reply.
    public var threadCommentCount: Int
    public var requestedReviewers: [String]
    public var stack: StackInfo?
    public var viewerIsAuthor = false
    /// The viewer's latest submitted review: APPROVED, CHANGES_REQUESTED, COMMENTED or DISMISSED.
    public var viewerReviewState: String?
    /// The commit that review was made on.
    public var viewerReviewedOid: String?
    /// Comments in the viewer's unsubmitted review on GitHub; nil when there is no pending review.
    public var pendingReviewComments: Int?
    /// Unresolved threads the viewer is part of (their PR, or a thread they started) where someone else spoke last.
    public var threadsAwaitingReply = 0
    /// Lines added and removed across the whole PR, and how many files it touches.
    public var additions = 0
    public var deletions = 0
    public var changedFiles = 0
    /// MERGEABLE, CONFLICTING or UNKNOWN: GitHub computes it lazily, so the first answer is often UNKNOWN.
    public var mergeable: String?
    /// DIRTY, BEHIND, BLOCKED, CLEAN, UNSTABLE, HAS_HOOKS, DRAFT or UNKNOWN.
    public var mergeStateStatus: String?
    /// Everyone else's review, by login: their latest APPROVED or CHANGES_REQUESTED, else their latest COMMENTED
    /// or DISMISSED one.
    public var reviewsByOthers: [String: String] = [:]

    public var ref: PRRef { PRRef(nameWithOwner: repo, number: number) }
    public var stackPosition: Int? { stack?.entries.first { $0.id == id }?.position }

    /// Open and can't be merged cleanly into its base.
    public var hasConflicts: Bool { state == "OPEN" && mergeable == "CONFLICTING" }
    /// Open and its base has commits it doesn't have yet (merging is blocked until it's updated).
    public var isBehind: Bool { state == "OPEN" && mergeStateStatus == "BEHIND" }
    /// GitHub hasn't computed mergeability yet: worth asking again on the next poll.
    public var mergeabilityPending: Bool { state == "OPEN" && mergeable == "UNKNOWN" }

    /// Open, not the viewer's own, already reviewed by them, and the head moved since: new commits to look at.
    /// A dismissed review counts too (stale approvals are usually dismissed because of new pushes).
    public var needsReReview: Bool {
        state == "OPEN" && !viewerIsAuthor && viewerReviewState != nil
            && viewerReviewedOid.map { $0 != headRefOid } == true
    }

    /// The pull request of `prs` that a GitHub PR link (`https://github.com/o/r/pull/1`) points to.
    public static func linked(by url: URL, in prs: some Sequence<PullRequest>) -> PullRequest? {
        guard let ref = PRRef(url.absoluteString) else { return nil }
        return prs.first { $0.repo.lowercased() == ref.nameWithOwner.lowercased() && $0.number == ref.number }
    }
}

public struct Comment: Hashable, Identifiable, Sendable {
    /// GitHub edits and deletes the two kinds through different mutations.
    public enum Kind: Hashable, Sendable { case issue, review }

    public var id: String
    public var author: String
    public var body: String
    public var createdAt: Date
    /// Part of the viewer's unsubmitted review (only the viewer sees it).
    public var isPending = false
    public var kind = Kind.issue
    public var viewerCanUpdate = false
    public var viewerCanDelete = false
    public var viewerCanReact = false
    public var reactions: [Reaction] = []
    /// Hidden on GitHub, e.g. as resolved: conversation comments can't be resolved like review threads.
    public var isMinimized = false
    public var viewerCanMinimize = false
    /// The review an inline comment was posted with.
    public var reviewID: String?
}

public enum ReactionContent: String, CaseIterable, Hashable, Sendable {
    case thumbsUp = "THUMBS_UP", thumbsDown = "THUMBS_DOWN", laugh = "LAUGH", hooray = "HOORAY"
    case confused = "CONFUSED", heart = "HEART", rocket = "ROCKET", eyes = "EYES"

    public var emoji: String {
        switch self {
        case .thumbsUp: "👍"
        case .thumbsDown: "👎"
        case .laugh: "😄"
        case .hooray: "🎉"
        case .confused: "😕"
        case .heart: "❤️"
        case .rocket: "🚀"
        case .eyes: "👀"
        }
    }

    /// GitHub's name for the reaction, shown as its tooltip.
    public var name: String {
        switch self {
        case .thumbsUp: "+1"
        case .thumbsDown: "-1"
        default: rawValue.capitalized
        }
    }
}

public struct Reaction: Hashable, Sendable {
    public var content: ReactionContent
    public var count: Int
    public var viewerHasReacted: Bool
}

public struct Review: Hashable, Identifiable, Sendable {
    public var id: String
    public var author: String
    public var state: String
    public var body: String
    public var submittedAt: Date?
    /// The commit it was made on; only read for the latest reviews.
    public var commitOID: String?
}

/// One line of GitHub's Reviewers box.
public struct Reviewer: Hashable, Sendable {
    public var login: String
    /// APPROVED, CHANGES_REQUESTED, COMMENTED or DISMISSED; nil while their review is requested.
    public var state: String?
    /// Their review was made on an older commit than the head.
    public var isOutdated = false
}

public struct ReviewThread: Hashable, Identifiable, Sendable {
    public var id: String
    public var path: String
    public var line: Int?
    public var side: DiffSide
    public var isResolved: Bool
    public var isOutdated: Bool
    public var comments: [Comment]
    public var viewerCanResolve = false
    public var viewerCanUnresolve = false
    public var resolvedBy: String?

    /// Everyone who wrote in the thread, in order of their first comment.
    public var participants: [String] {
        comments.map(\.author).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// "alice, bob, you +2": the first `limit` participants, the viewer as "you".
    public func participantList(viewer: String, limit: Int = 3) -> String {
        let names = participants.map { $0 == viewer ? "you" : $0 }
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? "\(shown) +\(names.count - limit)" : shown
    }

    /// The viewer wrote the first comment.
    public func isStarted(by viewer: String) -> Bool { !viewer.isEmpty && comments.first?.author == viewer }

    /// The viewer wrote any comment, pending ones (a reply not submitted yet) included.
    public func hasComment(from viewer: String) -> Bool { !viewer.isEmpty && comments.contains { $0.author == viewer } }

    /// The viewer started it, replied in it (also with a pending reply) or is `@mentioned` in it.
    public func involves(_ viewer: String) -> Bool {
        hasComment(from: viewer) || comments.contains { ReviewThread.mentions(viewer, in: $0.body) }
    }

    /// `text` `@mentions` the viewer (case-insensitively, not as part of a longer login or an email address).
    static func mentions(_ viewer: String, in text: String) -> Bool {
        guard !viewer.isEmpty else { return false }
        let mention = "(?<![\\w-])@\(NSRegularExpression.escapedPattern(for: viewer))(?![\\w-])"
        return text.range(of: mention, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The first non-blank line of the first comment, code fences skipped: what the thread is about, at a glance.
    public var topic: String {
        let lines = (comments.first?.body ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first { !$0.isEmpty && !$0.hasPrefix("```") } ?? ""
    }
    /// GitHub's diff hunk for the first comment: the patch up to the commented line.
    public var diffHunk = ""
}

public struct PendingComment: Hashable, Identifiable, Sendable {
    public var id: String
    public var path: String
    public var line: Int?
    public var body: String
}

public struct PendingReview: Hashable, Sendable {
    public var id: String
    public var commitOID: String?
    public var comments: [PendingComment]
}

public struct PRDetail: Sendable {
    public var body: String
    public var comments: [Comment]
    public var reviews: [Review]
    public var threads: [ReviewThread]
    /// The viewer's own pending review, if any: GitHub only shows a user their own.
    public var pendingReview: PendingReview?
    /// APPROVED, CHANGES_REQUESTED or REVIEW_REQUIRED; nil when the base branch requires no review.
    public var reviewDecision: String?
    /// Each reviewer's latest review; their latest approval or change request when they have one.
    public var latestReviews: [Review] = []
    /// The latest 100 commits, oldest first, and how many there are in all.
    public var commits: [PRCommit] = []
    public var commitCount = 0

    /// Like GitHub's Reviewers box, without the viewer (shown apart) and the author: requested reviewers wait,
    /// everyone else shows their latest review.
    public func reviewers(of pr: PullRequest, viewer: String) -> [Reviewer] {
        let reviewed = latestReviews.filter { !pr.requestedReviewers.contains($0.author) }.map {
            Reviewer(login: $0.author, state: $0.state, isOutdated: $0.commitOID.map { $0 != pr.headRefOid } ?? false)
        }
        return (reviewed + pr.requestedReviewers.map { Reviewer(login: $0) }).filter { $0.login != viewer && $0.login != pr.author }
    }

    /// Unresolved threads where someone else wrote last and it's the viewer's turn: their PR, or a thread they
    /// started. The rule behind `PullRequest.threadsAwaitingReply`, on the loaded threads.
    public func threadsAwaitingReply(_ pr: PullRequest, viewer: String) -> [ReviewThread] {
        threads.filter { thread in
            !thread.isResolved && thread.comments.last.map { $0.author != viewer } == true
                && (pr.viewerIsAuthor || thread.isStarted(by: viewer))
        }
    }
}

public struct PRCommit: Hashable, Identifiable, Sendable {
    public var oid: String
    public var abbreviatedOid: String
    public var headline: String
    /// GitHub login, or the git author name when the email isn't linked to an account.
    public var author: String
    public var date: Date?

    public var id: String { oid }
}

public struct FileChange: Codable, Hashable, Sendable {
    public var filename: String
    public var status: String
    public var additions: Int
    public var deletions: Int
    /// GitHub omits it for binary or very large diffs.
    public var patch: String?
}

public enum GitHubError: Error, LocalizedError, Equatable {
    case graphQL([String])
    case notLoggedIn(String)
    case notFound(String)
    /// Two commits that aren't one history: the older one was rebased or rewritten away.
    case rewritten

    public var errorDescription: String? {
        switch self {
        case .graphQL(let messages): messages.joined(separator: "\n")
        case .notLoggedIn(let detail): "GitHub CLI is not logged in. Run `gh auth login`.\n\(detail)"
        case .notFound(let what): "\(what) not found or not accessible."
        case .rewritten: "The older commit isn't in the newer one's history anymore: the branch was rebased or rewritten."
        }
    }
}

// MARK: - Client

/// All GitHub access goes through the `gh` CLI, which owns authentication.
public struct GitHub: Sendable {
    public let runner: any CommandRunner

    public init(runner: any CommandRunner) { self.runner = runner }

    /// Returns the `data` object of a GraphQL response.
    @discardableResult
    /// Errors whose `type` is in `tolerating` keep the partial data (e.g. NOT_FOUND for one id in a batch).
    public func graphql(_ query: String, _ variables: [String: any Sendable] = [:], tolerating: Set<String> = []) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let result = try await runner.run("gh", ["api", "graphql", "--input", "-"], stdin: body)
        let json = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
        if let errors = json?["errors"] as? [[String: Any]], !errors.isEmpty {
            let fatal = errors.filter { !tolerating.contains($0["type"] as? String ?? "") }
            if fatal.isEmpty, let data = json?["data"] as? [String: Any] { return data }
            throw GitHubError.graphQL((fatal.isEmpty ? errors : fatal).compactMap { $0["message"] as? String })
        }
        guard result.status == 0, let data = json?["data"] as? [String: Any] else {
            throw CommandError.failed(tool: "gh", status: result.status, stderr: result.stderr)
        }
        return data
    }

    public func viewerLogin() async throws -> String {
        let status = try await runner.run("gh", ["auth", "status", "--active"])
        guard status.status == 0 else { throw GitHubError.notLoggedIn(status.stderr + status.text) }
        let data = try await graphql("query { viewer { login } }")
        return (data["viewer"] as? [String: Any])?["login"] as? String ?? ""
    }

    /// PRs authored by, assigned to, or awaiting review from the viewer, as id → last update.
    /// Only ids and dates: GitHub prices a search at its worst case, so the full PR fragment here cost
    /// 306 of the 5,000 hourly points per poll. This costs 1.
    public func inbox() async throws -> [String: Date] {
        let fields = "nodes { ... on PullRequest { id updatedAt } }"
        let data = try await graphql("""
        query {
          authored: search(query: "is:pr is:open archived:false author:@me", type: ISSUE, first: 50) { \(fields) }
          assigned: search(query: "is:pr is:open archived:false assignee:@me", type: ISSUE, first: 50) { \(fields) }
          requested: search(query: "is:pr is:open archived:false review-requested:@me", type: ISSUE, first: 50) { \(fields) }
        }
        """)
        return Self.stamps(["authored", "assigned", "requested"].flatMap { Self.nodes(data[$0]) })
    }

    /// Last update per PR id, 100 ids per point. Deleted or inaccessible PRs are left out.
    public func updatedAt(ids: [String]) async throws -> [String: Date] {
        var result: [String: Date] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            let data = try await graphql("query($ids: [ID!]!) { nodes(ids: $ids) { ... on PullRequest { id updatedAt } } }",
                                         ["ids": chunk], tolerating: ["NOT_FOUND"])
            result.merge(Self.stamps((data["nodes"] as? [Any] ?? []).compactMap { $0 as? [String: Any] })) { a, _ in a }
        }
        return result
    }

    public func pullRequest(_ ref: PRRef) async throws -> PullRequest {
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) { pullRequest(number: $number) { ...PR } }
        }
        """ + Self.prFragment
        let data = try await graphql(query, ["owner": ref.owner, "name": ref.repo, "number": ref.number])
        guard let node = (data["repository"] as? [String: Any])?["pullRequest"] as? [String: Any],
              let pr = Self.decodePR(node) else { throw GitHubError.notFound("\(ref.nameWithOwner)#\(ref.number)") }
        return pr
    }

    /// One cheap batched query per poll for every followed PR.
    public func pullRequests(ids: [String]) async throws -> [PullRequest] {
        var result: [PullRequest] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let chunk = Array(ids[start..<min(start + 50, ids.count)])
            let query = "query($ids: [ID!]!) { nodes(ids: $ids) { ...PR } }" + Self.prFragment
            // A deleted PR or one this account can't see must not hide all the others.
            let data = try await graphql(query, ["ids": chunk], tolerating: ["NOT_FOUND"])
            result += ((data["nodes"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any]).flatMap(Self.decodePR) }
        }
        return result
    }

    /// Every PR in `stamps`: the cached copy when GitHub hasn't updated it since, fetched otherwise.
    /// Cached PRs missing from `stamps` are dropped. Returns the ids that were fetched.
    public func pullRequests(updatedAt stamps: [String: Date], cached: [String: PullRequest]) async throws
        -> (prs: [String: PullRequest], fetched: [String]) {
        var prs = cached.filter { stamps[$0.key] != nil }
        let fetched = Updates.changed(stamps, cached: prs)
        for pr in try await pullRequests(ids: fetched) { prs[pr.id] = pr }
        return (prs, fetched)
    }

    public func detail(id: String) async throws -> PRDetail {
        let query = """
        query($id: ID!) { node(id: $id) { ... on PullRequest {
          body
          comments(last: 100) { nodes { ...CommentFields } }
          reviews(last: 50) { nodes { id author { login } state body submittedAt } }
          reviewThreads(first: 100) { nodes { id path line diffSide isResolved isOutdated viewerCanResolve viewerCanUnresolve resolvedBy { login }
            comments(first: 100) { nodes { ...CommentFields state diffHunk pullRequestReview { id } } } } }
          \(Self.pendingField)
          reviewDecision latestReviews(first: 20) { nodes { ...LatestReview } }
          latestOpinionatedReviews(first: 20) { nodes { ...LatestReview } }
          commitCount: commits { totalCount }
          commits(last: 100) { nodes { commit { oid abbreviatedOid messageHeadline committedDate author { name user { login } } } } }
        } } }
        fragment LatestReview on PullRequestReview { id author { login } state body submittedAt commit { oid } }
        fragment CommentFields on Comment {
          __typename id author { login } body createdAt
          ... on Updatable { viewerCanUpdate }
          ... on Deletable { viewerCanDelete }
          ... on Reactable { viewerCanReact reactionGroups { content viewerHasReacted reactors { totalCount } } }
          ... on Minimizable { isMinimized viewerCanMinimize }
        }
        """
        let data = try await graphql(query, ["id": id])
        guard let pr = data["node"] as? [String: Any] else { throw GitHubError.notFound("Pull request") }
        let pending = Self.decodePending(pr["pending"])
        return PRDetail(
            body: pr["body"] as? String ?? "",
            comments: Self.nodes(pr["comments"]).map(Self.decodeComment),
            reviews: Self.nodes(pr["reviews"]).filter { $0["state"] as? String != "PENDING" }.map(Self.decodeReview),
            threads: Self.nodes(pr["reviewThreads"]).map {
                ReviewThread(id: $0["id"] as? String ?? "", path: $0["path"] as? String ?? "", line: $0["line"] as? Int,
                             side: DiffSide(rawValue: $0["diffSide"] as? String ?? "") ?? .right,
                             isResolved: $0["isResolved"] as? Bool ?? false, isOutdated: $0["isOutdated"] as? Bool ?? false,
                             comments: Self.nodes($0["comments"]).map(Self.decodeComment),
                             viewerCanResolve: $0["viewerCanResolve"] as? Bool ?? false,
                             viewerCanUnresolve: $0["viewerCanUnresolve"] as? Bool ?? false,
                             resolvedBy: ($0["resolvedBy"] as? [String: Any])?["login"] as? String,
                             diffHunk: Self.nodes($0["comments"]).first?["diffHunk"] as? String ?? "")
            },
            pendingReview: pending,
            reviewDecision: pr["reviewDecision"] as? String,
            latestReviews: Self.latestReviews(Self.nodes(pr["latestReviews"]).map(Self.decodeReview),
                                              opinionated: Self.nodes(pr["latestOpinionatedReviews"]).map(Self.decodeReview)),
            commits: Self.nodes(pr["commits"]).compactMap { $0["commit"] as? [String: Any] }.map {
                let author = $0["author"] as? [String: Any]
                return PRCommit(oid: $0["oid"] as? String ?? "", abbreviatedOid: $0["abbreviatedOid"] as? String ?? "",
                                headline: $0["messageHeadline"] as? String ?? "",
                                author: ((author?["user"] as? [String: Any])?["login"] ?? author?["name"]) as? String ?? "ghost",
                                date: Self.date($0["committedDate"]))
            },
            commitCount: Self.total(pr["commitCount"])
        )
    }

    /// Each reviewer's latest review, where an approval or change request wins over later plain comments:
    /// replying in a thread after approving is a COMMENTED review and would otherwise hide the approval.
    static func latestReviews(_ latest: [Review], opinionated: [Review]) -> [Review] {
        let decided = Dictionary(opinionated.map { ($0.author, $0) }) { first, _ in first }
        return latest.map { decided[$0.author] ?? $0 } + opinionated.filter { review in !latest.contains { $0.author == review.author } }
    }

    /// Only the viewer's pending review: what review writes need, without the whole conversation.
    public func pendingReview(prID: String) async throws -> PendingReview? {
        let data = try await graphql("query($id: ID!) { node(id: $id) { ... on PullRequest { \(Self.pendingField) } } }", ["id": prID])
        return Self.decodePending((data["node"] as? [String: Any])?["pending"])
    }

    static let pendingField = """
    pending: reviews(states: PENDING, first: 1) { nodes { id commit { oid } comments(first: 100) { nodes { id path line body } } } }
    """

    static func decodePending(_ connection: Any?) -> PendingReview? {
        nodes(connection).first.map { review in
            PendingReview(
                id: review["id"] as? String ?? "",
                commitOID: (review["commit"] as? [String: Any])?["oid"] as? String,
                comments: nodes(review["comments"]).map {
                    PendingComment(id: $0["id"] as? String ?? "", path: $0["path"] as? String ?? "", line: $0["line"] as? Int, body: $0["body"] as? String ?? "")
                }
            )
        }
    }

    public func files(_ ref: PRRef) async throws -> [FileChange] {
        let data = try await runner.output("gh", ["api", "repos/\(ref.nameWithOwner)/pulls/\(ref.number)/files?per_page=100", "--paginate", "--slurp"])
        return try JSONDecoder().decode([[FileChange]].self, from: data).flatMap { $0 }
    }

    /// Paths the viewer marked as viewed on GitHub. A file changed since it was marked (DISMISSED) counts as unviewed.
    public func viewedFiles(prID: String) async throws -> Set<String> {
        let query = """
        query($id: ID!, $after: String) { node(id: $id) { ... on PullRequest {
          files(first: 100, after: $after) { nodes { path viewerViewedState } pageInfo { hasNextPage endCursor } }
        } } }
        """
        var viewed: Set<String> = []
        var after: String?
        repeat {
            var variables: [String: any Sendable] = ["id": prID]
            if let after { variables["after"] = after }
            let data = try await graphql(query, variables)
            let files = (data["node"] as? [String: Any])?["files"] as? [String: Any]
            viewed.formUnion(Self.nodes(files).filter { $0["viewerViewedState"] as? String == "VIEWED" }.compactMap { $0["path"] as? String })
            let page = files?["pageInfo"] as? [String: Any]
            after = page?["hasNextPage"] as? Bool == true ? page?["endCursor"] as? String : nil
        } while after != nil
        return viewed
    }

    public func setViewed(prID: String, path: String, viewed: Bool) async throws {
        let mutation = viewed ? "markFileAsViewed" : "unmarkFileAsViewed"
        try await graphql("""
        mutation($id: ID!, $path: String!) { \(mutation)(input: {pullRequestId: $id, path: $path}) { clientMutationId } }
        """, ["id": prID, "path": path])
    }

    public func editComment(_ comment: Comment, body: String) async throws {
        let mutation = switch comment.kind {
        case .issue: "updateIssueComment(input: {id: $id, body: $body}) { clientMutationId }"
        case .review: "updatePullRequestReviewComment(input: {pullRequestReviewCommentId: $id, body: $body}) { clientMutationId }"
        }
        try await graphql("mutation($id: ID!, $body: String!) { \(mutation) }", ["id": comment.id, "body": body])
    }

    public func deleteComment(_ comment: Comment) async throws {
        let mutation = comment.kind == .issue ? "deleteIssueComment" : "deletePullRequestReviewComment"
        try await graphql("mutation($id: ID!) { \(mutation)(input: {id: $id}) { clientMutationId } }", ["id": comment.id])
    }

    public func setReaction(_ content: ReactionContent, on subjectID: String, reacted: Bool) async throws {
        let mutation = reacted ? "addReaction" : "removeReaction"
        try await graphql("""
        mutation($id: ID!, $content: ReactionContent!) { \(mutation)(input: {subjectId: $id, content: $content}) { clientMutationId } }
        """, ["id": subjectID, "content": content.rawValue])
    }

    public func setResolved(threadID: String, resolved: Bool) async throws {
        let mutation = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        try await graphql("mutation($id: ID!) { \(mutation)(input: {threadId: $id}) { clientMutationId } }", ["id": threadID])
    }

    /// Hides a conversation comment as resolved, GitHub's equivalent of resolving it, or shows it again.
    public func setHiddenAsResolved(commentID: String, hidden: Bool) async throws {
        let mutation = hidden
            ? "minimizeComment(input: {subjectId: $id, classifier: RESOLVED}) { clientMutationId }"
            : "unminimizeComment(input: {subjectId: $id}) { clientMutationId }"
        try await graphql("mutation($id: ID!) { \(mutation) }", ["id": commentID])
    }

    /// File texts at a commit, 50 per GraphQL query (1 point each), instead of one REST call per file all at once,
    /// which could trip GitHub's concurrency limit on big PRs. Binary, truncated or missing files are left out.
    public func fileContents(repo: String, paths: [String], ref: String) async throws -> [String: String] {
        let name = PRRef(nameWithOwner: repo, number: 0)
        var result: [String: String] = [:]
        for start in stride(from: 0, to: paths.count, by: 50) {
            let chunk = Array(paths[start..<min(start + 50, paths.count)])
            let fields = chunk.indices.map { "f\($0): object(expression: $e\($0)) { ... on Blob { text isBinary isTruncated } }" }
            let query = """
            query($owner: String!, $name: String!, \(chunk.indices.map { "$e\($0): String!" }.joined(separator: ", "))) {
              repository(owner: $owner, name: $name) { \(fields.joined(separator: " ")) }
            }
            """
            var variables: [String: any Sendable] = ["owner": name.owner, "name": name.repo]
            for (index, path) in chunk.enumerated() { variables["e\(index)"] = "\(ref):\(path)" }
            let repository = try await graphql(query, variables)["repository"] as? [String: Any] ?? [:]
            for (index, path) in chunk.enumerated() {
                guard let blob = repository["f\(index)"] as? [String: Any], blob["isBinary"] as? Bool != true,
                      blob["isTruncated"] as? Bool != true, let text = blob["text"] as? String else { continue }
                result[path] = text
            }
        }
        return result
    }

    public struct TreeEntry: Decodable, Hashable, Sendable {
        public var path: String
        public var size: Int
    }

    public struct TreeListing: Decodable, Sendable {
        /// Paths from the repository root.
        public var tree: [TreeEntry]
        /// GitHub stopped listing (past about 100,000 entries or 7 MB): some files are missing from `tree`.
        public var truncated: Bool
    }

    /// Every file of a repository at a ref (`HEAD` for the default branch), or only under the folder `path`, with
    /// its size in bytes. Asking for the folder's own tree keeps big repositories under GitHub's listing limit.
    /// Throws when `path` isn't a folder.
    public func tree(repo: String, ref: String, path: String = "") async throws -> TreeListing {
        guard ContextSource.isRepositoryName(repo), !(ref + "/" + path).split(separator: "/").contains("..") else {
            throw GitHubError.notFound("Repository “\(repo)” at “\(ref)”")
        }
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text }
        let object = path.isEmpty ? encode(ref) : "\(encode(ref)):\(encode(path))" // `ref:path` names the folder's tree
        let data = try await runner.output("gh", ["api", "repos/\(repo)/git/trees/\(object)?recursive=1",
                                                  "--jq", #"{truncated, tree: [.tree[] | select(.type == "blob") | {path, size}]}"#])
        var listing = try JSONDecoder().decode(TreeListing.self, from: data)
        if !path.isEmpty { listing.tree = listing.tree.map { TreeEntry(path: path + "/" + $0.path, size: $0.size) } }
        return listing
    }

    /// Paths that differ between two commits (used to tell whether a draft went stale).
    public func changedPaths(repo: String, from base: String, to head: String) async throws -> Set<String> {
        let data = try await runner.output("gh", ["api", "repos/\(repo)/compare/\(base)...\(head)", "--jq", "[.files[].filename]"])
        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    /// The changed files and their patches between two commits. Throws when the older one is gone (e.g. after a
    /// force-push) or no longer in the newer one's history (a rebase: GitHub then compares from their merge base,
    /// mixing in the base branch's changes), so callers can fall back to the whole PR diff.
    public func compareFiles(repo: String, from base: String, to head: String) async throws -> [FileChange] {
        struct Comparison: Decodable {
            var status: String
            var files: [FileChange]?
        }
        let data: Data
        do {
            data = try await runner.output("gh", ["api", "repos/\(repo)/compare/\(base)...\(head)", "--jq", "{status, files}"])
        } catch CommandError.failed(_, _, let stderr) where stderr.contains("HTTP 404") || stderr.contains("HTTP 422") {
            throw GitHubError.notFound("Commit \(base.prefix(7))") // gone, or a root commit's missing parent
        }
        let comparison = try JSONDecoder().decode(Comparison.self, from: data)
        guard ["ahead", "identical"].contains(comparison.status) else { throw GitHubError.rewritten }
        return comparison.files ?? []
    }

    /// How many commits were pushed on top of `base` to reach `head`. Nil when `head` doesn't simply extend `base`
    /// (a rebase, force-push or merge from the base branch makes them diverge, and GitHub's count means nothing then).
    /// Throws when `base` is gone.
    public func commitsAhead(repo: String, from base: String, to head: String) async throws -> Int? {
        let data = try await runner.output("gh", ["api", "repos/\(repo)/compare/\(base)...\(head)",
                                                  "--jq", #"if .status == "ahead" then .ahead_by else null end"#])
        return try JSONDecoder().decode(Int?.self, from: data)
    }

    /// GitHub's page for exactly the commits between two heads (two dots: after a rebase, three dots would show the
    /// whole pull request plus the base branch's changes).
    public static func compareURL(repo: String, from base: String, to head: String) -> URL? {
        URL(string: "https://github.com/\(repo)/compare/\(base)..\(head)")
    }

    // MARK: Decoding

    static let prFragment = """

    fragment PR on PullRequest {
      id number title url state isDraft updatedAt headRefOid headRefName baseRefName additions deletions changedFiles
      mergeable mergeStateStatus
      author { login } repository { nameWithOwner }
      comments { totalCount } reviews { totalCount }
      viewerDidAuthor viewerLatestReview { state commit { oid } }
      latestReviews(first: 20) { nodes { state viewerDidAuthor author { login } } }
      latestOpinionatedReviews(first: 20) { nodes { state viewerDidAuthor author { login } } }
      pendingReview: reviews(states: PENDING, first: 1) { nodes { comments { totalCount } } }
      reviewThreads(first: 100) { nodes { isResolved
        comments(last: 1) { totalCount nodes { viewerDidAuthor } }
        starter: comments(first: 1) { nodes { viewerDidAuthor } } } }
      reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { name } } } }
      stack { number entries(first: 50) { nodes { position pullRequest { id number } } } }
    }
    """

    static func decodePR(_ node: [String: Any]) -> PullRequest? {
        guard let id = node["id"] as? String, let number = node["number"] as? Int else { return nil }
        let stack = (node["stack"] as? [String: Any]).map { stack in
            StackInfo(
                number: stack["number"] as? Int ?? 0,
                entries: nodes(stack["entries"]).compactMap { entry -> StackInfo.Entry? in
                    guard let pr = entry["pullRequest"] as? [String: Any], let id = pr["id"] as? String else { return nil }
                    return StackInfo.Entry(position: entry["position"] as? Int ?? 0, id: id, number: pr["number"] as? Int ?? 0)
                }.sorted { $0.position < $1.position }
            )
        }
        return PullRequest(
            id: id, number: number,
            title: node["title"] as? String ?? "",
            url: node["url"] as? String ?? "",
            state: node["state"] as? String ?? "",
            isDraft: node["isDraft"] as? Bool ?? false,
            updatedAt: date(node["updatedAt"]) ?? .distantPast,
            headRefOid: node["headRefOid"] as? String ?? "",
            headRefName: node["headRefName"] as? String ?? "",
            baseRefName: node["baseRefName"] as? String ?? "",
            author: login(node),
            repo: (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? "",
            commentCount: total(node["comments"]),
            reviewCount: total(node["reviews"]),
            threadCommentCount: nodes(node["reviewThreads"]).reduce(0) { $0 + total($1["comments"]) },
            requestedReviewers: nodes(node["reviewRequests"]).compactMap {
                let reviewer = $0["requestedReviewer"] as? [String: Any]
                return (reviewer?["login"] ?? reviewer?["name"]) as? String
            },
            stack: stack,
            viewerIsAuthor: node["viewerDidAuthor"] as? Bool ?? false,
            viewerReviewState: (node["viewerLatestReview"] as? [String: Any])?["state"] as? String,
            viewerReviewedOid: ((node["viewerLatestReview"] as? [String: Any])?["commit"] as? [String: Any])?["oid"] as? String,
            pendingReviewComments: nodes(node["pendingReview"]).first.map { total($0["comments"]) },
            threadsAwaitingReply: awaitingReply(nodes(node["reviewThreads"]), viewerIsAuthor: node["viewerDidAuthor"] as? Bool ?? false),
            additions: node["additions"] as? Int ?? 0,
            deletions: node["deletions"] as? Int ?? 0,
            changedFiles: node["changedFiles"] as? Int ?? 0,
            mergeable: node["mergeable"] as? String,
            mergeStateStatus: node["mergeStateStatus"] as? String,
            // A thread reply is a COMMENTED review, so the latest review can hide an earlier approval or
            // change request: those come from the opinionated list and win.
            reviewsByOthers: (nodes(node["latestReviews"]) + nodes(node["latestOpinionatedReviews"]))
                .filter { $0["viewerDidAuthor"] as? Bool != true }
                .reduce(into: [:]) { $0[login($1)] = $1["state"] as? String }
        )
    }

    static func awaitingReply(_ threads: [[String: Any]], viewerIsAuthor: Bool) -> Int {
        threads.filter { thread in
            guard thread["isResolved"] as? Bool != true,
                  let last = nodes(thread["comments"]).last, last["viewerDidAuthor"] as? Bool == false else { return false }
            return viewerIsAuthor || nodes(thread["starter"]).first?["viewerDidAuthor"] as? Bool == true
        }.count
    }

    static func decodeReview(_ node: [String: Any]) -> Review {
        Review(id: node["id"] as? String ?? "", author: login(node), state: node["state"] as? String ?? "",
               body: node["body"] as? String ?? "", submittedAt: date(node["submittedAt"]),
               commitOID: (node["commit"] as? [String: Any])?["oid"] as? String)
    }

    static func decodeComment(_ node: [String: Any]) -> Comment {
        Comment(id: node["id"] as? String ?? "", author: login(node), body: node["body"] as? String ?? "",
                createdAt: date(node["createdAt"]) ?? .distantPast, isPending: node["state"] as? String == "PENDING",
                kind: node["__typename"] as? String == "PullRequestReviewComment" ? .review : .issue,
                viewerCanUpdate: node["viewerCanUpdate"] as? Bool ?? false,
                viewerCanDelete: node["viewerCanDelete"] as? Bool ?? false,
                viewerCanReact: node["viewerCanReact"] as? Bool ?? false,
                reactions: (node["reactionGroups"] as? [[String: Any]] ?? []).compactMap { group in
                    let count = total(group["reactors"])
                    guard count > 0, let content = ReactionContent(rawValue: group["content"] as? String ?? "") else { return nil }
                    return Reaction(content: content, count: count, viewerHasReacted: group["viewerHasReacted"] as? Bool ?? false)
                },
                isMinimized: node["isMinimized"] as? Bool ?? false,
                viewerCanMinimize: node["viewerCanMinimize"] as? Bool ?? false,
                reviewID: (node["pullRequestReview"] as? [String: Any])?["id"] as? String)
    }

    static func stamps(_ nodes: [[String: Any]]) -> [String: Date] {
        Dictionary(nodes.compactMap { node in (node["id"] as? String).map { ($0, date(node["updatedAt"]) ?? .distantPast) } }) { a, _ in a }
    }

    static func nodes(_ connection: Any?) -> [[String: Any]] {
        ((connection as? [String: Any])?["nodes"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    static func total(_ connection: Any?) -> Int { (connection as? [String: Any])?["totalCount"] as? Int ?? 0 }

    /// Deleted accounts come back as a null author.
    static func login(_ node: [String: Any]) -> String { (node["author"] as? [String: Any])?["login"] as? String ?? "ghost" }

    static func date(_ value: Any?) -> Date? { (value as? String).flatMap { try? Date($0, strategy: .iso8601) } }
}
