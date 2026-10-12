import Foundation
import Testing
@testable import ReviewDeskCore

private let review = #"{"summary":"ok","findings":[{"severity":"high","title":"t","rationale":"r","path":"a.py","line":3,"comment":"c"}]}"#
private let subscribed = ok(#"{"loggedIn":true,"authMethod":"claude.ai"}"#)

@Test func claudeRunsWithToolsHooksAndMCPDisabled() async throws {
    let runner = FakeRunner { call in
        call.args.first == "auth" ? subscribed : ok(#"{"type":"result","is_error":false,"structured_output":\#(review)}"#)
    }
    let result = try await AIReviewer(runner: runner).review(.claudeCode, prompt: "p")

    #expect(result.findings.first?.line == 3)
    let args = try #require(runner.calls.last?.args)
    for flag in ["-p", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"] { #expect(args.contains(flag)) }
    #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
    #expect(args[args.firstIndex(of: "--setting-sources")! + 1] == "")
    #expect(runner.calls.last?.stdin == Data("p".utf8))
}

@Test func claudeRefusesAPIKeyAuthentication() async {
    let runner = FakeRunner { _ in ok(#"{"loggedIn":true,"authMethod":"api_key"}"#) }
    await #expect(throws: AIError.notSubscription("Claude Code is authenticated via api_key")) {
        try await AIReviewer(runner: runner).review(.claudeCode, prompt: "p")
    }
    #expect(runner.calls.count == 1) // never ran the review
}

@Test func claudeLoginAndPlanErrorsAreSurfaced() async {
    let runner = FakeRunner { call in
        call.args.first == "auth" ? subscribed : CommandResult(status: 1, stdout: Data(#"{"is_error":true,"result":"Usage limit reached"}"#.utf8))
    }
    await #expect(throws: AIError.failed("Usage limit reached")) { try await AIReviewer(runner: runner).review(.claudeCode, prompt: "p") }
}

@Test func codexRunsReadOnlyWithoutHooksAndReadsOutputFile() async throws {
    let runner = FakeRunner { call in
        if call.args.first == "login" { return ok("Logged in using ChatGPT\n") }
        let output = call.args[call.args.firstIndex(of: "-o")! + 1]
        try Data(review.utf8).write(to: URL(fileURLWithPath: output))
        return ok("")
    }
    let result = try await AIReviewer(runner: runner).review(.codex, prompt: "p")

    #expect(result.summary == "ok")
    let args = try #require(runner.calls.last?.args)
    #expect(args[args.firstIndex(of: "--sandbox")! + 1] == "read-only")
    for flag in ["--ignore-user-config", "--ignore-rules", "--ephemeral"] { #expect(args.contains(flag)) }
    #expect(args.indices.filter { args[$0] == "--disable" }.map { args[$0 + 1] } == ["hooks", "plugins"])
}

@Test func codexRefusesAPIKeyLogin() async {
    let runner = FakeRunner { _ in ok("Logged in using an API key - sk-***\n") }
    await #expect(throws: AIError.self) { try await AIReviewer(runner: runner).review(.codex, prompt: "p") }
    #expect(runner.calls.count == 1)
}

@Test func invalidOutputIsReported() async {
    let runner = FakeRunner { call in call.args.first == "list" ? ok("") : ok("not json") }
    await #expect(throws: AIError.invalidOutput("not json")) { try await AIReviewer(runner: runner).review(.ollama(model: "qwen"), prompt: "p") }
}

@Test func timeoutAndCancellationPropagate() async {
    let runner = FakeRunner { call in
        if call.args.first == "auth" { return subscribed }
        throw CommandError.timedOut("claude")
    }
    await #expect(throws: CommandError.timedOut("claude")) { try await AIReviewer(runner: runner).review(.claudeCode, prompt: "p") }

    let slow = ProcessRunner(paths: ["claude": "/bin/sleep"])
    let task = Task { try await AIReviewer(runner: slow).review(.claudeCode, prompt: "p") }
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
}

@Test func onlyOllamaIsLocal() {
    #expect(AIEngine.ollama(model: "m").isLocal)
    #expect(!AIEngine.claudeCode.isLocal && !AIEngine.codex.isLocal)
}

@Test func linkedSessionReviewForksWithoutSavingAndKeepsToolsOff() async throws {
    let runner = FakeRunner { call in
        call.args.first == "auth" ? subscribed : ok(#"{"type":"result","is_error":false,"structured_output":\#(review)}"#)
    }
    let engine = AIEngine.claudeSession(id: "S1", name: "fix-matters", cwd: "/Users/me/lexroom/lexroom-backend")
    let result = try await AIReviewer(runner: runner).review(engine, prompt: "p")

    #expect(result.summary == "ok")
    let call = try #require(runner.calls.last)
    #expect(call.args[call.args.firstIndex(of: "--resume")! + 1] == "S1")
    for flag in ["--fork-session", "--no-session-persistence", "--strict-mcp-config"] { #expect(call.args.contains(flag)) }
    #expect(call.args[call.args.firstIndex(of: "--tools")! + 1] == "")
    #expect(call.cwd?.path == "/Users/me/lexroom/lexroom-backend")
    #expect(engine.name == "Claude Code · fix-matters" && !engine.isLocal)
}
