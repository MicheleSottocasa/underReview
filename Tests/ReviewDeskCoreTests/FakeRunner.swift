import Foundation
@testable import ReviewDeskCore

/// Answers commands from a closure and records every call.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    struct Call {
        var tool: String
        var args: [String]
        var stdin: Data?
        var cwd: URL?

        /// The GraphQL request body sent through `gh api graphql --input -`.
        var graphQL: [String: Any]? { stdin.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        var query: String { graphQL?["query"] as? String ?? "" }
        var variables: [String: Any] { graphQL?["variables"] as? [String: Any] ?? [:] }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (Call) throws -> CommandResult

    init(_ respond: @escaping @Sendable (Call) throws -> CommandResult) { self.respond = respond }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ tool: String, _ args: [String], stdin: Data?, cwd: URL?, timeout: Duration) async throws -> CommandResult {
        let call = Call(tool: tool, args: args, stdin: stdin, cwd: cwd)
        lock.withLock { recorded.append(call) }
        return try respond(call)
    }
}

func ok(_ json: String) -> CommandResult { CommandResult(status: 0, stdout: Data(json.utf8)) }

func data(_ json: String) -> CommandResult { ok(#"{"data":\#(json)}"#) }

/// A PR node in the shape GitHub returns for the `PR` fragment.
/// `threads` entries: (comments, resolved, last comment is the viewer's, viewer started it).
func prNode(id: String = "PR_1", number: Int = 1, head: String = "aaa", state: String = "OPEN", comments: Int = 0,
            reviews: Int = 0, threadComments: [Int] = [], requested: [String] = [], stack: String = "null",
            author: Bool = false, latestReview: String? = nil, reviewedAt: String = "aaa", pending: Int? = nil,
            threads: [(comments: Int, resolved: Bool, lastMine: Bool, startedByMe: Bool)] = [], closedAt: String? = nil) -> String {
    let allThreads = threadComments.map { ($0, false, true, true) } + threads.map { ($0.comments, $0.resolved, $0.lastMine, $0.startedByMe) }
    let threadJSON = allThreads.map { count, resolved, lastMine, mine in
        #"{"isResolved":\#(resolved),"comments":{"totalCount":\#(count),"nodes":[{"viewerDidAuthor":\#(lastMine)}]},"starter":{"nodes":[{"viewerDidAuthor":\#(mine)}]}}"#
    }.joined(separator: ",")
    return """
    {"id":"\(id)","number":\(number),"title":"T\(number)","url":"https://github.com/o/r/pull/\(number)","state":"\(state)",
     "isDraft":false,"updatedAt":"2026-10-12T14:27:55Z","closedAt":\(closedAt.map { "\"\($0)\"" } ?? "null"),"headRefOid":"\(head)","headRefName":"h\(number)","baseRefName":"main",
     "additions":120,"deletions":7,"changedFiles":3,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY",
     "author":{"login":"alice"},"repository":{"nameWithOwner":"o/r"},
     "comments":{"totalCount":\(comments)},"reviews":{"totalCount":\(reviews)},
     "viewerDidAuthor":\(author),"viewerLatestReview":\(latestReview.map { #"{"state":"\#($0)","commit":{"oid":"\#(reviewedAt)"}}"# } ?? "null"),
     "pendingReview":{"nodes":[\(pending.map { #"{"comments":{"totalCount":\#($0)}}"# } ?? "")]},
     "reviewThreads":{"nodes":[\(threadJSON)]},
     "reviewRequests":{"nodes":[\(requested.map { #"{"requestedReviewer":{"login":"\#($0)"}}"# }.joined(separator: ","))]},
     "stack":\(stack)}
    """
}

/// The events of a `/code-review` that read the diff successfully: a `gh pr diff` call and its result.
let diffReadEvents = [
    #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_diff","name":"Bash","input":{"command":"gh pr diff 1 -R o/r"}}]}}"#,
    #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_diff","is_error":false,"content":"diff --git a/a.py b/a.py"}]}}"#,
].joined(separator: "\n")
