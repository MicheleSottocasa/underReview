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
    #expect(ClaudeAgents.repo(fromRemote: "ssh://git@ssh.github.com:443/o/r.git") == "o/r")
    #expect(ClaudeAgents.repo(fromRemote: "https://github.com/o/r/") == "o/r")
    #expect(ClaudeAgents.repo(fromRemote: "git@github-work:o/r.git") == nil)
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

@Test func readsStoredSessionsNewestFirstAndSkipsSuperseded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID())")
    let folder = root.appendingPathComponent("-x-lexroom-backend")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ name: String, _ lines: [String], age: TimeInterval) throws {
        let url = folder.appendingPathComponent("\(name).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }
    let user = #"{"type":"user","cwd":"/x/lexroom-backend","gitBranch":"feat/a","message":{"content":"Review the auth flow\nplease"}}"#
    try write("old", [user], age: 300)
    try write("titled", [#"{"type":"user","cwd":"/x/lexroom-backend","message":{"content":"<local-command-caveat>"}}"#, user,
                         #"{"type":"custom-title","customTitle":"auth0-review-1386"}"#], age: 100)
    try write("superseded", [user, #"{"type":"continued-in","continuedInSessionId":"titled"}"#], age: 10)
    try write("no-cwd", [#"{"type":"mode","mode":"normal"}"#], age: 5)

    let runner = FakeRunner { _ in ok("https://github.com/Lexroom-ai/lexroom-backend.git") }
    let sessions = await ClaudeAgents(runner: runner).recent(projects: root)

    #expect(sessions.map(\.sessionID) == ["titled", "old"])
    #expect(sessions[0].name == "auth0-review-1386" && sessions[0].branch == "feat/a" && sessions[0].status == "stopped")
    #expect(sessions[1].name == "Review the auth flow please")
    #expect(sessions.allSatisfy { $0.repo == "Lexroom-ai/lexroom-backend" })
    #expect(runner.calls.count == 1) // remote resolved once per folder
}
