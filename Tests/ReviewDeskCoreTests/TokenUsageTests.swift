import Foundation
import Testing
@testable import ReviewDeskCore

/// Claude Code 2.1's final event after `/code-review`: the work ran in a helper agent, so the top-level usage is all
/// zeros and only `modelUsage` has the numbers.
private var codeReviewResult: [String: Any] { [
    "type": "result", "total_cost_usd": 0.0554534,
    "usage": ["input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0],
    "modelUsage": ["claude-opus-5-5": ["inputTokens": 6, "outputTokens": 297, "cacheReadInputTokens": 15097,
                                        "cacheCreationInputTokens": 9294, "costUSD": 0.0554534, "costBasis": "list"]],
] }

@Test func readsClaudeUsageFromModelUsageFirst() throws {
    let usage = try #require(TokenUsage.claude(codeReviewResult))
    #expect(usage == TokenUsage(input: 6, output: 297, cacheRead: 15097, cacheWrite: 9294, listPriceUSD: 0.0554534))
    #expect(usage.total == 24694)
    // Without modelUsage, the top-level usage stands in; nothing at all is no usage.
    let plain = TokenUsage.claude(["usage": ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100]])
    #expect(plain == TokenUsage(input: 10, output: 5, cacheRead: 100))
    #expect(TokenUsage.claude(["usage": ["input_tokens": 0, "output_tokens": 0]]) == nil)
}

@Test func readsCodexUsageFromItsJSONEvents() throws {
    let events = """
    {"type":"thread.started","thread_id":"x"}
    {"type":"turn.started"}
    {"type":"item.completed"}
    {"type":"turn.completed","usage":{"input_tokens":15318,"cached_input_tokens":6912,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}
    """
    let usage = try #require(TokenUsage.codex(events: events))
    #expect(usage == TokenUsage(input: 8406, output: 5, cacheRead: 6912)) // input_tokens includes the cached part
    #expect(TokenUsage.codex(events: "not json") == nil)
}

@Test func readsOllamaUsageFromVerboseStats() throws {
    let stderr = """
    total duration:       4.2s
    load duration:        1.1s
    prompt eval count:    1240 token(s)
    prompt eval duration: 900ms
    eval count:           312 token(s)
    eval duration:        2.1s
    """
    #expect(TokenUsage.ollama(stderr: stderr) == TokenUsage(input: 1240, output: 312))
    #expect(TokenUsage.ollama(stderr: "Error: model not found") == nil)
}

@Test func meterAddsPassesAndNotesCallsWithoutUsage() {
    let meter = UsageMeter()
    meter.add(TokenUsage(input: 10, output: 1, listPriceUSD: 0.01))
    meter.add(TokenUsage(input: 5, output: 2))
    #expect(meter.usage == TokenUsage(input: 15, output: 3, listPriceUSD: 0.01, passes: 2))
    #expect(meter.complete)
    meter.add(nil)
    #expect(!meter.complete)
    #expect(UsageMeter().usage == nil)
}

@Test func formatsTokenCountsAndSummaries() {
    #expect(TokenUsage.formatted(950) == "950")
    #expect(TokenUsage.formatted(8_406) == "8.4k")
    #expect(TokenUsage.formatted(84_200) == "84k")
    #expect(TokenUsage.formatted(1_340_000) == "1.3M")
    #expect(TokenUsage(input: 6, output: 297, cacheRead: 15097, cacheWrite: 9294, passes: 2).summary == "25k tokens (6 in, 297 out, 24k cached) · 2 passes")
}

@Test func reviewerRecordsUsageOfEveryPass() async throws {
    let structured = #"{"type":"result","is_error":false,"structured_output":{"summary":"s","findings":[],"keyAreas":[],"risks":[]},"modelUsage":{"m":{"inputTokens":100,"outputTokens":50}}}"#
    let runner = FakeRunner { call in
        if call.args.first == "auth" { return ok(#"{"loggedIn":true,"authMethod":"claude.ai"}"#) }
        return ok(structured)
    }
    let meter = UsageMeter()
    _ = try await AIReviewer(runner: runner).review(.claudeCode, prompt: "p", usage: meter)
    #expect(meter.usage == TokenUsage(input: 100, output: 50))
}

@Test func runsSavedBeforeUsageWasRecordedStillLoad() throws {
    var run = AIRun(prID: "PR_1", engine: .claudeCode, headRefOid: "h", result: ReviewResult(summary: "s", findings: []))
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as! [String: Any]
    json["usage"] = nil
    json["estimatedTokens"] = nil
    let old = try JSONDecoder().decode(AIRun.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.usage == nil && old.estimatedTokens == nil)

    run.usage = TokenUsage(input: 1, output: 2, listPriceUSD: 0.5)
    #expect(try JSONDecoder().decode(AIRun.self, from: JSONEncoder().encode(run)).usage == run.usage)

    let check = FollowUpRun(prID: "PR_1", engine: .codex, headRefOid: "h", reviewedOid: nil, result: FollowUpResult(summary: "s", items: []))
    var checkJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(check)) as! [String: Any]
    checkJSON["usage"] = nil
    #expect(try JSONDecoder().decode(FollowUpRun.self, from: JSONSerialization.data(withJSONObject: checkJSON)).usage == nil)
}
