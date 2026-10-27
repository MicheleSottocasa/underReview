import Foundation
import Testing
@testable import ReviewDeskCore

private let review = #"{"summary":"ok","findings":[{"severity":"high","title":"t","rationale":"r","path":"a.py","line":3,"comment":"c"}]}"#
private let subscribed = ok(#"{"loggedIn":true,"authMethod":"claude.ai"}"#)

@Test func aRunIsOutdatedOnceTheAuthorPushes() {
    let pr = PullRequest(id: "PR_1", number: 1, title: "T", url: "", state: "OPEN", isDraft: false, updatedAt: .now,
                         headRefOid: "def5678aaaa", headRefName: "", baseRefName: "", author: "", repo: "o/r",
                         commentCount: 0, reviewCount: 0, threadCommentCount: 0, requestedReviewers: [], stack: nil)
    let run = AIRun(prID: pr.id, engine: .claudeCode, headRefOid: "abc1234bbbb", result: ReviewResult(summary: "", findings: []))
    #expect(run.isOutdated(for: pr))
    #expect(!AIRun(prID: pr.id, engine: .codex, headRefOid: pr.headRefOid, result: run.result).isOutdated(for: pr))
    var unknown = pr
    unknown.headRefOid = "" // GitHub gave no head: no banner
    #expect(!run.isOutdated(for: unknown))
    #expect(run.outdatedMessage(for: pr, commits: 3) == "The author pushed 3 commits since this analysis (abc1234 → def5678).")
    #expect(run.outdatedMessage(for: pr, commits: 1).contains("pushed 1 commit since"))
    #expect(run.outdatedMessage(for: pr, commits: nil).contains("pushed new commits since"))
}

@Test func aFixIsProposedWithoutAnyTools() async throws {
    let runner = FakeRunner { call in
        call.args.first == "auth" ? subscribed
            : ok(#"{"type":"result","is_error":false,"structured_output":{"startLine":3,"line":3,"suggestion":"x = 1","comment":"c"}}"#)
    }
    let fix = try await AIReviewer(runner: runner).structured(.claudeCode, prompt: "p", schema: AIContext.fixSchema, as: FixProposal.self)
    #expect(fix.suggestion == "x = 1")
    let args = try #require(runner.calls.last?.args)
    #expect(args[args.firstIndex(of: "--tools")! + 1] == "" && args.contains("--disable-slash-commands"))
    #expect(!args.contains("--add-dir") && !args.contains("--allowedTools"))
    #expect(args[args.firstIndex(of: "--json-schema")! + 1] == AIContext.fixSchema)
}

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

@Test func askReturnsPlainTextWithoutASchema() async throws {
    let runner = FakeRunner { call in
        call.args.first == "auth" ? subscribed : ok(#"{"type":"result","is_error":false,"result":"  It means X.\n"}"#)
    }
    #expect(try await AIReviewer(runner: runner).ask(.claudeCode, prompt: "p") == "It means X.")
    let args = try #require(runner.calls.last?.args)
    #expect(!args.contains("--json-schema"))
    #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
}

@Test func askWithOllamaSkipsJSONFormat() async throws {
    let runner = FakeRunner { call in call.args.first == "list" ? ok("") : ok("Plain answer") }
    #expect(try await AIReviewer(runner: runner).ask(.ollama(model: "m"), prompt: "p") == "Plain answer")
    #expect(runner.calls.last?.args == ["run", "m", "--hidethinking", "--verbose"])
}

private let context = ReviewContext(title: "T", body: "B", files: [
    ContextFile(path: "a.py", patch: "@@ -1 +1,9 @@\n+x", content: nil, included: true),
], budget: 10_000)

/// First call: `/code-review` returns its text report. Second: the structuring pass returns JSON.
private func codeReviewRunner(report: String = "1. a.py:3 off by one") -> FakeRunner {
    FakeRunner { call in
        if call.args.first == "auth" { return subscribed }
        if call.args.contains("--json-schema") {
            return ok(#"{"type":"result","is_error":false,"structured_output":{"summary":"ok","findings":[],"keyAreas":[{"path":"a.py","startLine":3,"endLine":9,"reason":"r","risk":"data"}]}}"#)
        }
        return ok(diffReadEvents + "\n" + #"{"type":"result","is_error":false,"result":"\#(report)"}"#)
    }
}

@Test func codeReviewRunsTheCommandWithModelEffortAndReadOnlyTools() async throws {
    let runner = codeReviewRunner()
    let review = try await AIReviewer(runner: runner).codeReview(
        .claudeCode, prURL: "https://github.com/o/r/pull/1", context: context,
        options: AIOptions(model: "opus", effort: "xhigh"), instructions: "be kind")

    #expect(review.keyAreas == [KeyArea(path: "a.py", startLine: 3, endLine: 9, reason: "r", risk: "data")])
    let reviews = runner.calls.filter { $0.args.first == "-p" }
    #expect(reviews.count == 2)
    let command = reviews[0]
    let stdin = String(decoding: command.stdin ?? Data(), as: UTF8.self)
    #expect(stdin.hasPrefix("/code-review xhigh https://github.com/o/r/pull/1 (ReviewDesk: There is no checkout"))
    func value(_ call: FakeRunner.Call, _ flag: String) -> String? { call.args.firstIndex(of: flag).map { call.args[$0 + 1] } }
    #expect(value(command, "--model") == "opus")
    #expect(value(command, "--effort") == "xhigh")
    #expect(value(command, "--append-system-prompt")?.hasPrefix("be kind\n\nThere is no checkout") == true)
    #expect(value(command, "--permission-prompts") == "none")
    #expect(value(command, "--allowedTools") == "Read,Grep,Glob,Agent,Bash(gh pr diff:*),Bash(gh pr view:*)")
    for flag in ["--restricted", "--strict-mcp-config"] { #expect(command.args.contains(flag)) }
    // Persisted so the helper's transcript can be followed live; the files are removed after the run.
    #expect(!command.args.contains("--no-session-persistence"))
    // A schema makes print mode skip the command's report, so only the second pass uses one.
    #expect(!command.args.contains("--json-schema"))
    #expect(!command.args.contains("--disable-slash-commands"))

    let structure = reviews[1]
    #expect(value(structure, "--tools") == "")
    #expect(value(structure, "--model") == "opus")
    let prompt = String(decoding: structure.stdin ?? Data(), as: UTF8.self)
    #expect(prompt.contains("1. a.py:3 off by one"))
    #expect(prompt.contains("## Diff: a.py"))
}

@Test func codeReviewStreamsItsStepsAndReadsTheFinalResult() async throws {
    let runner = FakeRunner { call in
        if call.args.first == "auth" { return subscribed }
        if call.args.contains("--json-schema") {
            return ok(#"{"type":"result","is_error":false,"structured_output":{"summary":"ok","findings":[],"keyAreas":[],"risks":[]}}"#)
        }
        return ok(([diffReadEvents] + streamedReview).joined(separator: "\n"))
    }
    let steps = Steps()
    _ = try await AIReviewer(runner: runner).codeReview(.claudeCode, prURL: "u", context: context, options: AIOptions()) { steps.append($0) }
    #expect(steps.value.first == "Starting /code-review (high)…")
    #expect(steps.value.contains("Reading `cmd/setdefault.go`"))
    #expect(steps.value.last == "Turning the review into findings, key areas and risk answers…")
    let command = try #require(runner.calls.first { $0.args.contains("-p") })
    #expect(command.args.contains("stream-json") && command.args.contains("--verbose") && command.args.contains("--forward-subagent-text"))
    // The structuring pass got the report from the final result event.
    let structure = try #require(runner.calls.last)
    #expect(String(decoding: structure.stdin ?? Data(), as: UTF8.self).contains("## Review from /code-review\n\nNo problems found."))
}

private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    var value: [String] { lock.withLock { steps } }
    func append(_ step: String) { lock.withLock { steps.append(step) } }
}

@Test func codeReviewKeepsTheCLIDefaultModelWhenNoneIsChosen() async throws {
    let runner = codeReviewRunner()
    _ = try await AIReviewer(runner: runner).codeReview(.claudeCode, prURL: "u", context: context, options: AIOptions())
    #expect(!runner.calls.contains { $0.args.contains("--model") })
}

@Test func codeReviewReadsProjectFoldersThroughAddDirWithTheSameReadOnlyTools() async throws {
    let runner = codeReviewRunner()
    _ = try await AIReviewer(runner: runner).codeReview(.claudeCode, prURL: "u", context: context, options: AIOptions(),
                                                        folders: ["/docs/api", "/src/lib"])
    let args = try #require(runner.calls.first { $0.args.contains("--restricted") }?.args)
    #expect(args.indices.filter { args[$0] == "--add-dir" }.map { args[$0 + 1] } == ["/docs/api", "/src/lib"])
    #expect(args[args.firstIndex(of: "--tools")! + 1] == "Read,Grep,Glob,Bash,Agent")
    #expect(args[args.firstIndex(of: "--allowedTools")! + 1] == AIReviewer.codeReviewAllowed)
    #expect(args[args.firstIndex(of: "--append-system-prompt")! + 1].hasSuffix("/docs/api, /src/lib"))
    // Hidden files in them stay denied (checked live: Read is refused, Grep and Glob don't list them).
    let deny = try #require(args.firstIndex(of: "--disallowedTools"))
    #expect(Array(args[(deny + 1)...].prefix(4)) == ["Read(//docs/api/**/.*)", "Read(//docs/api/**/.*/**)",
                                                     "Read(//src/lib/**/.*)", "Read(//src/lib/**/.*/**)"])
    // The tool-less structuring pass never gets the folders.
    #expect(!(runner.calls.first { $0.args.contains("--json-schema") }?.args.contains("--add-dir") ?? true))
}

// Regression: with no checkout, /code-review tried `gh pr checkout`, `git clone` and listing the home folder.
@Test func codeReviewReadsTheCheckoutAndIsToldNotToCloneOrSearch() async throws {
    let runner = codeReviewRunner()
    _ = try await AIReviewer(runner: runner).codeReview(.claudeCode, prURL: "u", context: context, options: AIOptions(),
                                                        folders: ["/docs/api"], checkout: "/tmp/r-7")
    let args = try #require(runner.calls.first { $0.args.contains("--restricted") }?.args)
    #expect(args.indices.filter { args[$0] == "--add-dir" }.map { args[$0 + 1] } == ["/tmp/r-7", "/docs/api"])
    #expect(args.contains("Read(//tmp/r-7/**/.*)"))
    let prompt = args[args.firstIndex(of: "--append-system-prompt")! + 1]
    #expect(prompt.contains("are in /tmp/r-7") && prompt.contains("Don't run git, clone, check out or fetch anything"))
    #expect(prompt.contains("cd, other commands, pipes, redirections, && and ; are refused") && prompt.hasSuffix("/docs/api"))
    #expect(!prompt.contains("There is no checkout"))
    // The helper agent doing the review only gets the command's arguments, so the same rules follow the URL there,
    // with no word the command would take for a flag.
    let stdin = String(decoding: try #require(runner.calls.first { $0.args.contains("--restricted") }?.stdin), as: UTF8.self)
    let rules = try #require(prompt.components(separatedBy: "\n\n").last)
    #expect(stdin == "/code-review high u (ReviewDesk: \(rules))")
    #expect(!stdin.split(separator: " ").contains { $0.hasPrefix("--") } && !stdin.contains("`"))
}

@Test func codeReviewFailsWhenTheCommandProducesNoReport() async {
    let runner = codeReviewRunner(report: "Command completed")
    await #expect(throws: AIError.invalidOutput("/code-review returned no report")) {
        try await AIReviewer(runner: runner).codeReview(.claudeCode, prURL: "u", context: context, options: AIOptions())
    }
}

@Test func structuringPassLeavesOverBudgetDiffsOutByName() {
    var big = context
    big.budget = big.tokens // exactly a.py; b.py won't fit
    big.files.append(ContextFile(path: "b.py", patch: String(repeating: "+y\n", count: 50), content: nil, included: true))
    let fitted = big.fittingBudget()
    #expect(fitted.files.map(\.included) == [true, false])
    #expect(AIContext.structurePrompt(report: "r", context: fitted).contains("not provided: b.py"))
}

@Test func reviewsSavedBeforeKeyAreasStillLoad() throws {
    let old = try JSONDecoder().decode(ReviewResult.self, from: Data(#"{"summary":"s","findings":[]}"#.utf8))
    #expect(old.keyAreas.isEmpty)
}

@Test func codeReviewFailsWhenItNeverReadTheDiff() async throws {
    // Issue #30: opened from Finder, `gh` wasn't on PATH, so `gh pr diff` failed and the review "found nothing".
    let refused = [
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gh pr diff 1 -R o/r"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"command not found: gh"}]}}"#,
        #"{"type":"result","is_error":false,"result":"No review was done: gh was not installed."}"#,
    ].joined(separator: "\n")
    for output in [refused, #"{"type":"result","is_error":false,"result":"No findings."}"#] {
        let runner = FakeRunner { call in call.args.first == "auth" ? subscribed : ok(output) }
        await #expect(throws: AIError.self) {
            try await AIReviewer(runner: runner).codeReview(.claudeCode, prURL: "u", context: context, options: AIOptions())
        }
        #expect(!runner.calls.contains { $0.args.contains("--json-schema") }) // no structuring pass on an empty review
    }
}

/// Writes a session's files where Claude Code would: the main stream says only that a helper started; the diff is read
/// in `diffAgent`'s transcript, which isn't the one followed live (as with a nested agent) and isn't forwarded.
private func sessionRunner(config: URL, session: String = "S1", diffAgent: String?, structured: String) -> FakeRunner {
    FakeRunner { call in
        if call.args.first == "auth" { return subscribed }
        if call.args.contains("--json-schema") { return ok(structured) }
        let files = ClaudeSessionFiles(configDirectory: config, cwd: try #require(call.cwd), session: session)
        try FileManager.default.createDirectory(at: files.transcript(task: "T1").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Reviewing."}]}}"#.utf8).write(to: files.transcript(task: "T1"))
        if let diffAgent {
            try Data([
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"d1","name":"Bash","input":{"command":"gh pr diff 1 -R o/r"}}]}}"#,
                #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"d1","is_error":false,"content":"diff --git a/a.py b/a.py"}]}}"#,
            ].joined(separator: "\n").utf8).write(to: files.transcript(task: diffAgent))
        }
        return ok([
            #"{"type":"system","subtype":"task_started","session_id":"\#(session)","task_id":"T1","description":"/code-review"}"#,
            #"{"type":"result","is_error":false,"result":"One finding in a.py."}"#,
        ].joined(separator: "\n"))
    }
}

private let structuredResult = #"{"type":"result","is_error":false,"structured_output":{"summary":"ok","findings":[],"keyAreas":[],"risks":[]}}"#

@Test func codeReviewCountsADiffReadByANestedAgent() async throws {
    // Issue #99: a real review was rejected as "couldn't read the diff" though its report said it had read it.
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("rd-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: config) }
    let runner = sessionRunner(config: config, diffAgent: "T2-nested", structured: structuredResult)
    let review = try await AIReviewer(runner: runner, claudeConfigDirectory: config)
        .codeReview(.claudeCode, prURL: "u", context: context, options: AIOptions())
    #expect(review.summary == "ok")
    let left = (try? FileManager.default.contentsOfDirectory(atPath: config.appendingPathComponent("projects").path)) ?? []
    #expect(left.isEmpty) // the run's files are still removed afterwards
}

@Test func codeReviewStillFailsWhenNoTranscriptReadTheDiff() async throws {
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("rd-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: config) }
    let runner = sessionRunner(config: config, diffAgent: nil, structured: structuredResult)
    await #expect(throws: AIError.self) {
        try await AIReviewer(runner: runner, claudeConfigDirectory: config)
            .codeReview(.claudeCode, prURL: "u", context: context, options: AIOptions())
    }
}

@Test func linkedSessionsOnlyCountTheForkedSessionsTranscripts() async throws {
    // A diff the linked session read earlier, in its own files, says nothing about this review.
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("rd-config-\(UUID().uuidString)")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rd-linked-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: config); try? FileManager.default.removeItem(at: folder) }
    let earlier = ClaudeSessionFiles(configDirectory: config, cwd: folder, session: "LINKED")
    try FileManager.default.createDirectory(at: earlier.transcript(task: "OLD").deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"o1","name":"Bash","input":{"command":"gh pr diff 1 -R o/r"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"o1","is_error":false,"content":"diff"}]}}"#,
    ].joined(separator: "\n").utf8).write(to: earlier.transcript(task: "OLD"))
    let runner = sessionRunner(config: config, session: "FORK", diffAgent: nil, structured: structuredResult)
    await #expect(throws: AIError.self) {
        try await AIReviewer(runner: runner, claudeConfigDirectory: config)
            .codeReview(.claudeSession(id: "LINKED", name: "n", cwd: folder.path), prURL: "u", context: context, options: AIOptions())
    }
    #expect(FileManager.default.fileExists(atPath: earlier.transcript(task: "OLD").path)) // the linked session's files stay
}

/// Answers `codex login status` and writes `review` to the `-o` file, like `codex exec`.
private func codexRunner() -> FakeRunner {
    FakeRunner { call in
        if call.args.first == "login" { return ok("Logged in using ChatGPT\n") }
        if let index = call.args.firstIndex(of: "-o") { try Data(review.utf8).write(to: URL(fileURLWithPath: call.args[index + 1])) }
        return ok("")
    }
}

@Test func codexRunsWithTheChosenModelAndEffort() async throws {
    let runner = codexRunner()
    _ = try await AIReviewer(runner: runner).review(.codex, prompt: "p", options: AIOptions(model: "gpt-5-codex", effort: "minimal"))
    let args = try #require(runner.calls.last?.args)
    #expect(args[args.firstIndex(of: "--model")! + 1] == "gpt-5-codex")
    #expect(args[args.firstIndex(of: "-c")! + 1] == "model_reasoning_effort=minimal")
    // The read-only sandbox and the ignored user config stay.
    #expect(args[args.firstIndex(of: "--sandbox")! + 1] == "read-only" && args.contains("--ignore-user-config"))

    _ = try await AIReviewer(runner: runner).review(.codex, prompt: "p", options: AIOptions(model: "", effort: ""))
    let defaults = try #require(runner.calls.last?.args)
    #expect(!defaults.contains("--model") && !defaults.contains("-c"))
}

@Test func ollamaThinksAtTheChosenLevel() async throws {
    let runner = FakeRunner { call in call.args.first == "list" ? ok("") : ok(review) }
    let reviewer = AIReviewer(runner: runner)
    _ = try await reviewer.review(.ollama(model: "gpt-oss"), prompt: "p", options: AIOptions(effort: "low"))
    #expect(runner.calls.last?.args == ["run", "gpt-oss", "--format", "json", "--think=low", "--hidethinking", "--verbose"])
    _ = try await reviewer.ask(.ollama(model: "qwen3"), prompt: "p", options: AIOptions(effort: "off"))
    #expect(runner.calls.last?.args == ["run", "qwen3", "--think=false", "--hidethinking", "--verbose"])
    _ = try await reviewer.ask(.ollama(model: "qwen3"), prompt: "p", options: AIOptions(effort: ""))
    #expect(runner.calls.last?.args == ["run", "qwen3", "--hidethinking", "--verbose"])
}

@Test func claudeCallsPassTheChosenModelAndEffort() async throws {
    let runner = FakeRunner { call in
        call.args.first == "auth" ? subscribed : ok(#"{"type":"result","is_error":false,"result":"A."}"#)
    }
    _ = try await AIReviewer(runner: runner).ask(.claudeCode, prompt: "p", options: AIOptions(model: "sonnet", effort: ""))
    let args = try #require(runner.calls.last?.args)
    #expect(args[args.firstIndex(of: "--model")! + 1] == "sonnet")
    #expect(!args.contains("--effort"))
}

@Test func optionsPassOnlyKnownEffortsAndModelNames() {
    // Nothing typed as a model may become a flag of its own.
    #expect(AIOptions(model: "--dangerously-skip-permissions", effort: "high").arguments(for: .claudeCode) == ["--effort", "high"])
    #expect(AIOptions(model: "opus --tools Bash", effort: "").arguments(for: .claudeCode) == [])
    #expect(AIOptions(model: "hf.co/org/model:Q4", effort: "").arguments(for: .codex) == ["--model", "hf.co/org/model:Q4"])
    #expect(AIOptions(model: "", effort: "max").arguments(for: .codex) == []) // a Claude level isn't Codex's
    #expect(AIOptions(model: "", effort: "x\nsandbox_mode=\"danger-full-access\"").arguments(for: .codex) == [])
    #expect(AIOptions(model: "ignored", effort: "high").arguments(for: .ollama(model: "m")) == ["--think=high"])
}

@Test func optionsDescribeHowARunWent() {
    #expect(AIOptions(model: "opus", effort: "high").label(for: .claudeCode) == "Opus · high")
    #expect(AIOptions(model: "", effort: "low").label(for: .claudeCode) == "default model · low")
    #expect(AIOptions(model: "gpt-5-codex", effort: "").label(for: .codex) == "GPT-5 Codex · default effort")
    #expect(AIOptions(model: "o-custom", effort: "high").label(for: .codex) == "o-custom · high effort")
    #expect(AIOptions(effort: "off").label(for: .ollama(model: "m")) == "no thinking")
    #expect(AIOptions(effort: "").label(for: .ollama(model: "m")) == "default thinking")
}

@Test func ollamaListsPulledModelsAndWhichCanThink() async {
    let list = """
    NAME                    ID              SIZE      MODIFIED
    qwen2.5-coder:latest    2b0496514337    4.7 GB    3 weeks ago
    gpt-oss:20b             aa4295ac10c3    13 GB     2 days ago
    """
    let show = """
      Model
        architecture        gptoss
        parameters          20.9B

      Capabilities
        completion
        tools
        thinking

      Parameters
        temperature    1
    """
    let runner = FakeRunner { call in
        switch call.args.first {
        case "list": ok(list)
        case "show": call.args.last == "gpt-oss:20b" ? ok(show) : ok(show.replacingOccurrences(of: "thinking", with: "insert"))
        default: CommandResult(status: 1, stdout: Data())
        }
    }
    let reviewer = AIReviewer(runner: runner)
    #expect(await reviewer.ollamaModels() == ["qwen2.5-coder:latest", "gpt-oss:20b"])
    #expect(await reviewer.ollamaThinks("gpt-oss:20b"))
    #expect(await !reviewer.ollamaThinks("qwen2.5-coder:latest"))
    #expect(await !reviewer.ollamaThinks("--help")) // never sent
    #expect(runner.calls.filter { $0.args.first == "show" }.count == 2)
    #expect(AIReviewer.ollamaThinks(show: "  Model\n    architecture  llama\n") == false) // older Ollama: no section
    #expect(await AIReviewer(runner: FakeRunner { _ in throw CommandError.toolNotFound("ollama") }).ollamaModels() == [])
}

@Test func claudeTakesPinnedVersionsAndTheLongContextWindow() async throws {
    #expect(AIOptions.claudeModel("opus", longContext: true) == "opus[1m]")
    #expect(AIOptions.claudeModel("claude-opus-5-5", longContext: true) == "claude-opus-5-5[1m]")
    #expect(AIOptions.claudeModel("opus[1m]", longContext: true) == "opus[1m]") // typed with it: not twice
    #expect(AIOptions.claudeModel("opus", longContext: false) == "opus")
    #expect(AIOptions.claudeModel("", longContext: true) == "") // Default passes nothing
    #expect(AIOptions.models(for: .claudeCode).contains(ModelChoice("claude-sonnet-5-5", "Sonnet 5.5")))
    #expect(AIOptions(model: "claude-opus-5-5[1m]", effort: "max").label(for: .claudeCode) == "Opus 5.5 · 1M context · max")
    #expect(AIOptions(model: "my-model[1m]", effort: "low").label(for: .claudeCode) == "my-model · 1M context · low")

    let runner = codeReviewRunner()
    _ = try await AIReviewer(runner: runner).codeReview(.claudeCode, prURL: "u", context: context,
                                                        options: AIOptions(model: "claude-opus-5-5[1m]", effort: "high"))
    for call in runner.calls.filter({ $0.args.first == "-p" }) {
        #expect(call.args[call.args.firstIndex(of: "--model")! + 1] == "claude-opus-5-5[1m]")
    }
}
