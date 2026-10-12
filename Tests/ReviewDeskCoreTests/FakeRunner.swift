import Foundation
@testable import ReviewDeskCore

/// Answers commands from a closure and records every call.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    struct Call {
        var tool: String
        var args: [String]
        var stdin: Data?

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
        let call = Call(tool: tool, args: args, stdin: stdin)
        lock.withLock { recorded.append(call) }
        return try respond(call)
    }
}

func ok(_ json: String) -> CommandResult { CommandResult(status: 0, stdout: Data(json.utf8)) }

func data(_ json: String) -> CommandResult { ok(#"{"data":\#(json)}"#) }

/// A PR node in the shape GitHub returns for the `PR` fragment.
func prNode(id: String = "PR_1", number: Int = 1, head: String = "aaa", state: String = "OPEN", comments: Int = 0,
            reviews: Int = 0, threadComments: [Int] = [], requested: [String] = [], stack: String = "null") -> String {
    """
    {"id":"\(id)","number":\(number),"title":"T\(number)","url":"https://github.com/o/r/pull/\(number)","state":"\(state)",
     "isDraft":false,"updatedAt":"2026-10-12T14:27:55Z","headRefOid":"\(head)","headRefName":"h\(number)","baseRefName":"main",
     "author":{"login":"alice"},"repository":{"nameWithOwner":"o/r"},
     "comments":{"totalCount":\(comments)},"reviews":{"totalCount":\(reviews)},
     "reviewThreads":{"nodes":[\(threadComments.map { #"{"comments":{"totalCount":\#($0)}}"# }.joined(separator: ","))]},
     "reviewRequests":{"nodes":[\(requested.map { #"{"requestedReviewer":{"login":"\#($0)"}}"# }.joined(separator: ","))]},
     "stack":\(stack)}
    """
}
