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
    /// Comments in the viewer's unsubmitted review on GitHub; nil when there is no pending review.
    public var pendingReviewComments: Int?
    /// Unresolved threads the viewer is part of (their PR, or a thread they started) where someone else spoke last.
    public var threadsAwaitingReply = 0

    public var ref: PRRef { PRRef(nameWithOwner: repo, number: number) }
    public var stackPosition: Int? { stack?.entries.first { $0.id == id }?.position }
}

public struct Comment: Hashable, Identifiable, Sendable {
    public var id: String
    public var author: String
    public var body: String
    public var createdAt: Date
    /// Part of the viewer's unsubmitted review (only the viewer sees it).
    public var isPending = false
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

    /// PRs authored by, assigned to, or awaiting review from the viewer.
    public func inbox() async throws -> [PullRequest] {
        let query = """
        query {
          authored: search(query: "is:pr is:open archived:false author:@me", type: ISSUE, first: 50) { nodes { ...PR } }
          assigned: search(query: "is:pr is:open archived:false assignee:@me", type: ISSUE, first: 50) { nodes { ...PR } }
          requested: search(query: "is:pr is:open archived:false review-requested:@me", type: ISSUE, first: 50) { nodes { ...PR } }
        }
        """ + Self.prFragment
        let data = try await graphql(query)
        var seen = Set<String>()
        return ["authored", "assigned", "requested"]
            .flatMap { ((data[$0] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] }
            .compactMap(Self.decodePR)
            .filter { seen.insert($0.id).inserted }
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
          comments(last: 100) { nodes { id author { login } body createdAt } }
          reviews(last: 50) { nodes { id author { login } state body submittedAt } }
          reviewThreads(first: 100) { nodes { id path line diffSide isResolved isOutdated
            comments(first: 100) { nodes { id author { login } body createdAt state } } } }
          pending: reviews(states: PENDING, first: 1) { nodes { id commit { oid }
            comments(first: 100) { nodes { id path line body } } } }
        } } }
        """
        let data = try await graphql(query, ["id": id])
        guard let pr = data["node"] as? [String: Any] else { throw GitHubError.notFound("Pull request") }
        let pending = Self.nodes(pr["pending"]).first.map { review in
            PendingReview(
                id: review["id"] as? String ?? "",
                commitOID: (review["commit"] as? [String: Any])?["oid"] as? String,
                comments: Self.nodes(review["comments"]).map {
                    PendingComment(id: $0["id"] as? String ?? "", path: $0["path"] as? String ?? "", line: $0["line"] as? Int, body: $0["body"] as? String ?? "")
                }
            )
        }
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
                             comments: Self.nodes($0["comments"]).map(Self.decodeComment))
            },
            pendingReview: pending
        )
    }

    public func files(_ ref: PRRef) async throws -> [FileChange] {
        let data = try await runner.output("gh", ["api", "repos/\(ref.nameWithOwner)/pulls/\(ref.number)/files?per_page=100", "--paginate", "--slurp"])
        return try JSONDecoder().decode([[FileChange]].self, from: data).flatMap { $0 }
    }

    public func fileContent(repo: String, path: String, ref: String) async throws -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let data = try await runner.output("gh", ["api", "repos/\(repo)/contents/\(encoded)?ref=\(ref)", "-H", "Accept: application/vnd.github.raw"])
        return String(decoding: data, as: UTF8.self)
    }

    /// Paths that differ between two commits (used to tell whether a draft went stale).
    public func changedPaths(repo: String, from base: String, to head: String) async throws -> Set<String> {
        let data = try await runner.output("gh", ["api", "repos/\(repo)/compare/\(base)...\(head)", "--jq", "[.files[].filename]"])
        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    // MARK: Decoding

    static let prFragment = """

    fragment PR on PullRequest {
      id number title url state isDraft updatedAt headRefOid headRefName baseRefName
      author { login } repository { nameWithOwner }
      comments { totalCount } reviews { totalCount }
      viewerDidAuthor viewerLatestReview { state }
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
                createdAt: date(node["createdAt"]) ?? .distantPast, isPending: node["state"] as? String == "PENDING")
    }

    static func nodes(_ connection: Any?) -> [[String: Any]] {
        ((connection as? [String: Any])?["nodes"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    static func total(_ connection: Any?) -> Int { (connection as? [String: Any])?["totalCount"] as? Int ?? 0 }

    /// Deleted accounts come back as a null author.
    static func login(_ node: [String: Any]) -> String { (node["author"] as? [String: Any])?["login"] as? String ?? "ghost" }

    static func date(_ value: Any?) -> Date? { (value as? String).flatMap { try? Date($0, strategy: .iso8601) } }
}
