import Foundation
import Testing
@testable import ReviewDeskCore

private let listing = """
[{"id":"65703f3d","cwd":"/Users/me/lexroom/lexroom-backend","kind":"background","sessionId":"S1","name":"Fix matters","state":"blocked"},
 {"pid":14628,"cwd":"/Users/me/lexroom/app_lex","kind":"interactive","sessionId":"S2","name":"app-lex-fa","status":"idle"},
 {"kind":"interactive"}]
"""

@Test func listsBackgroundAndInteractiveSessions() async throws {
    let runner = FakeRunner { call in
        if call.tool == "git" {
            return call.args[1].hasSuffix("lexroom-backend") ? ok("git@github.com:Lexroom-ai/lexroom-backend.git\n") : CommandResult(status: 128, stdout: Data())
        }
        #expect(call.args == ["agents", "--json"])
        return ok(listing)
    }
    let agents = try await ClaudeAgents(runner: runner).list()

    #expect(agents.map(\.sessionID) == ["S1", "S2"])
    #expect(agents[0].isBackground && agents[0].shortID == "65703f3d" && agents[0].status == "blocked")
    #expect(!agents[1].isBackground && agents[1].pid == 14628 && agents[1].status == "idle")
    #expect(agents.map(\.repo) == ["Lexroom-ai/lexroom-backend", nil])
    #expect(runner.calls.filter { $0.tool == "git" }.map { $0.args } == [
        ["-C", "/Users/me/lexroom/lexroom-backend", "remote", "get-url", "origin"],
        ["-C", "/Users/me/lexroom/app_lex", "remote", "get-url", "origin"],
    ])
}

@Test func parsesGitHubRemotes() {
    #expect(ClaudeAgents.repo(fromRemote: "https://github.com/Lexroom-ai/lexroom-backend.git") == "Lexroom-ai/lexroom-backend")
    #expect(ClaudeAgents.repo(fromRemote: "git@github.com:o/r.git\n") == "o/r")
    #expect(ClaudeAgents.repo(fromRemote: "https://gitlab.com/o/r.git") == nil)
}

@Test func logsAndStopOnlyTouchBackgroundSessions() async throws {
    let runner = FakeRunner { _ in ok("last output") }
    let client = ClaudeAgents(runner: runner)
    let agents = try await ClaudeAgents(runner: FakeRunner { _ in ok(listing) }).list()

    #expect(try await client.logs(agents[0]) == "last output")
    try await client.stop(agents[0])
    #expect(try await client.logs(agents[1]) == "")
    try await client.stop(agents[1])
    #expect(runner.calls.map(\.args) == [["logs", "65703f3d"], ["stop", "65703f3d"]])
}

@Test func scopeKeepsOnlyAgentsInThePRRepo() {
    let pr = PRRef(nameWithOwner: "Lexroom-ai/lexroom-backend", number: 1386)
    let agents = [
        RunningAgent(sessionID: "repo", name: "matters", cwd: "/x/backend-checkout", status: "idle", repo: "lexroom-ai/LEXROOM-backend"),
        RunningAgent(sessionID: "named", name: "auth0-review-1386", cwd: "/x/lexroom-backend", status: "idle", repo: "Lexroom-ai/lexroom-backend"),
        RunningAgent(sessionID: "other-repo", name: "fix-1386", cwd: "/x/app_lex", status: "idle", repo: "Lexroom-ai/app_lex"),
        RunningAgent(sessionID: "no-remote", name: "scratch", cwd: "/tmp/lexroom-backend", status: "idle"),
        RunningAgent(sessionID: "unrelated", name: "notes", cwd: "/tmp/notes", status: "idle"),
    ]
    #expect(ClaudeAgents.inScope(agents, for: pr).map(\.sessionID) == ["named", "repo", "no-remote"])
    #expect(ClaudeAgents.relevance(agents[1], to: PRRef(nameWithOwner: "Lexroom-ai/lexroom-backend", number: 13860)) == 1)
}
