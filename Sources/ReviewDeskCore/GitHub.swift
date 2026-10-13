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

    public var ref: PRRef { PRRef(nameWithOwner: repo, number: number) }
    public var stackPosition: Int? { stack?.entries.first { $0.id == id }?.position }

    /// Open, not the viewer's own, already reviewed by them, and the head moved since: new commits to look at.
    /// A dismissed review counts too (stale approvals are usually dismissed because of new pushes).
    public var needsReReview: Bool {
        state == "OPEN" && !viewerIsAuthor && viewerReviewState != nil
            && viewerReviewedOid.map { $0 != headRefOid } == true
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

    public var errorDescription: String? {
        switch self {
        case .graphQL(let messages): messages.joined(separator: "\n")
        case .notLoggedIn(let detail): "GitHub CLI is not logged in. Run `gh auth login`.\n\(detail)"
        case .notFound(let what): "\(what) not found or not accessible."
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

    public func detail(id: String) async throws -> PRDetail {
        let query = """
        query($id: ID!) { node(id: $id) { ... on PullRequest {
          body
          comments(last: 100) { nodes { ...CommentFields } }
          reviews(last: 50) { nodes { id author { login } state body submittedAt } }
          reviewThreads(first: 100) { nodes { id path line diffSide isResolved isOutdated viewerCanResolve viewerCanUnresolve
            comments(first: 100) { nodes { ...CommentFields state } } } }
          \(Self.pendingField)
        } } }
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
            reviews: Self.nodes(pr["reviews"]).filter { $0["state"] as? String != "PENDING" }.map {
                Review(id: $0["id"] as? String ?? "", author: Self.login($0), state: $0["state"] as? String ?? "",
                       body: $0["body"] as? String ?? "", submittedAt: Self.date($0["submittedAt"]))
            },
            threads: Self.nodes(pr["reviewThreads"]).map {
                ReviewThread(id: $0["id"] as? String ?? "", path: $0["path"] as? String ?? "", line: $0["line"] as? Int,
                             side: DiffSide(rawValue: $0["diffSide"] as? String ?? "") ?? .right,
                             isResolved: $0["isResolved"] as? Bool ?? false, isOutdated: $0["isOutdated"] as? Bool ?? false,
                             comments: Self.nodes($0["comments"]).map(Self.decodeComment),
                             viewerCanResolve: $0["viewerCanResolve"] as? Bool ?? false,
                             viewerCanUnresolve: $0["viewerCanUnresolve"] as? Bool ?? false)
            },
            pendingReview: pending
        )
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

    /// Paths that differ between two commits (used to tell whether a draft went stale).
    public func changedPaths(repo: String, from base: String, to head: String) async throws -> Set<String> {
        let data = try await runner.output("gh", ["api", "repos/\(repo)/compare/\(base)...\(head)", "--jq", "[.files[].filename]"])
        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    /// The changed files and their patches between two commits. Throws when the older one is gone
    /// (e.g. after a force-push), so callers can fall back to the whole PR diff.
    public func compareFiles(repo: String, from base: String, to head: String) async throws -> [FileChange] {
        let data = try await runner.output("gh", ["api", "repos/\(repo)/compare/\(base)...\(head)", "--jq", ".files"])
        return try JSONDecoder().decode([FileChange].self, from: data)
    }

    // MARK: Decoding

    static let prFragment = """

    fragment PR on PullRequest {
      id number title url state isDraft updatedAt headRefOid headRefName baseRefName
      author { login } repository { nameWithOwner }
      comments { totalCount } reviews { totalCount }
      viewerDidAuthor viewerLatestReview { state commit { oid } }
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
            threadsAwaitingReply: awaitingReply(nodes(node["reviewThreads"]), viewerIsAuthor: node["viewerDidAuthor"] as? Bool ?? false)
        )
    }

    static func awaitingReply(_ threads: [[String: Any]], viewerIsAuthor: Bool) -> Int {
        threads.filter { thread in
            guard thread["isResolved"] as? Bool != true,
                  let last = nodes(thread["comments"]).last, last["viewerDidAuthor"] as? Bool == false else { return false }
            return viewerIsAuthor || nodes(thread["starter"]).first?["viewerDidAuthor"] as? Bool == true
        }.count
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
                viewerCanMinimize: node["viewerCanMinimize"] as? Bool ?? false)
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
