import Testing
@testable import ReviewDeskCore

private let listing = """
[{"id":"65703f3d","cwd":"/Users/me/lexroom/lexroom-backend","kind":"background","sessionId":"S1","name":"Fix matters","state":"blocked"},
 {"pid":14628,"cwd":"/Users/me/lexroom/app_lex","kind":"interactive","sessionId":"S2","name":"app-lex-fa","status":"idle"},
 {"kind":"interactive"}]
"""

@Test func listsBackgroundAndInteractiveSessions() async throws {
    let runner = FakeRunner { call in
        #expect(call.args == ["agents", "--json"])
        return ok(listing)
    }
    let agents = try await ClaudeAgents(runner: runner).list()

    #expect(agents.map(\.sessionID) == ["S1", "S2"])
    #expect(agents[0].isBackground && agents[0].shortID == "65703f3d" && agents[0].status == "blocked")
    #expect(!agents[1].isBackground && agents[1].pid == 14628 && agents[1].status == "idle")
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

@Test func agentsNamedAfterThePRThenInItsRepoComeFirst() async throws {
    var agents = try await ClaudeAgents(runner: FakeRunner { _ in ok(listing) }).list()
    agents.append(RunningAgent(sessionID: "S3", name: "auth0-review-1386", cwd: "/Users/me/lexroom/lexroom-backend", status: "idle"))
    let backend = PRRef(nameWithOwner: "Lexroom-ai/lexroom-backend", number: 1386)

    #expect(ClaudeAgents.sorted(agents, for: backend).map(\.sessionID) == ["S3", "S1", "S2"])
    #expect(ClaudeAgents.relevance(agents[2], to: PRRef(nameWithOwner: "o/other", number: 13860)) == 0) // whole numbers only
    #expect(ClaudeAgents.sorted(agents, for: PRRef(nameWithOwner: "Lexroom-ai/app_lex", number: 1)).first?.sessionID == "S2")
}
