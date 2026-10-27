import Foundation
import Testing
@testable import ReviewDeskCore

private let context = ReviewContext(
    title: "Add retries", body: "Retries failed uploads.",
    files: [ContextFile(path: "a.py", patch: "@@ -1 +1 @@\n-x\n+y {title}", content: "y {title}\n", included: true),
            ContextFile(path: "b.py", patch: "@@ -1 +1 @@\n-p\n+q", content: "q\n", included: false)],
    budget: 10_000,
    rules: [ContextFile(path: "AGENTS.md", content: "Never use print().", included: true)])

@Test func savedPromptsFillTheirPlaceholdersOnce() {
    var withConversation = context
    withConversation.conversation = AIContext.conversationText([
        Comment(id: "1", author: "alice", body: "Why retry three times?", createdAt: .now),
    ])
    let template = ReviewTemplate(name: "Mine", template: "T={title} D={description} R={rules} C={conversation}\n{diff}{files} {unknown} {title")
    let filled = template.filled(withConversation)
    #expect(filled.hasPrefix("T=Add retries D=Retries failed uploads."))
    #expect(filled.contains("Never use print()."))
    #expect(filled.contains("**alice**:\nWhy retry three times?"))
    #expect(filled.contains("## Diff: a.py\n```diff\n@@ -1 +1 @@\n-x\n+y {title}\n```")) // inserted text isn't filled again
    #expect(filled.contains("## Full file at head: a.py"))
    #expect(!filled.contains("b.py")) // deselected in Prepare Context
    #expect(filled.hasSuffix(" {unknown} {title")) // unknown or unclosed placeholders stay as typed
}

@Test func aSavedPromptAlwaysEndsWithTheResultFormat() {
    let prompt = ReviewTemplate(name: "Short", template: "Just look at {diff}").prompt(context)
    #expect(prompt.hasPrefix("Just look at \n## Diff: a.py"))
    #expect(prompt.hasSuffix(AIContext.resultFormat))
    #expect(AIContext.resultFormat.contains(AIContext.schema))
    // The starter lists every placeholder.
    for placeholder in ReviewTemplate.placeholders { #expect(ReviewTemplate.starter.contains("{\(placeholder.name)}")) }
}

@Test func savedPromptsRoundTripThroughTheirFile() throws {
    let file = JSONFile<[ReviewTemplate]>(FileManager.default.temporaryDirectory.appendingPathComponent("review-commands-\(UUID()).json"))
    defer { try? FileManager.default.removeItem(at: file.url) }
    #expect(file.load(default: []).isEmpty)
    let saved = [ReviewTemplate(name: "Security"), ReviewTemplate(name: "Short", template: "Review {diff}")]
    try file.save(saved)
    #expect(file.load(default: []) == saved)
}

@Test func eachProviderResolvesOnlyItsOwnCommands() {
    let saved = [ReviewTemplate(name: "Security")]
    let id = saved[0].id
    #expect(ReviewCommand.resolve(nil, for: .claudeCode, saved: saved) == .codeReview)
    #expect(ReviewCommand.resolve("generic", for: .claudeCode, saved: saved) == .generic)
    #expect(ReviewCommand.resolve("codex-review", for: .claudeCode, saved: saved) == .codeReview) // another provider's
    #expect(ReviewCommand.resolve(nil, for: .codex, saved: saved) == .generic)
    #expect(ReviewCommand.resolve("codex-review", for: .codex, saved: saved) == .codexReview)
    #expect(ReviewCommand.resolve(id.uuidString, for: .codex, saved: saved) == .generic) // saved prompts are Ollama's
    #expect(ReviewCommand.resolve(id.uuidString, for: .ollama(model: "m"), saved: saved) == .saved(id))
    #expect(ReviewCommand.resolve(UUID().uuidString, for: .ollama(model: "m"), saved: saved) == .generic) // deleted
    #expect(ReviewCommand.saved(id).label(saved: saved) == "Security")
    #expect(!ReviewCommand.codeReview.preparesContext && ReviewCommand.codexReview.preparesContext)
}

@Test func aRunNamesTheCommandItRan() {
    let result = ReviewResult(summary: "", findings: [])
    var old = AIRun(prID: "P", engine: .claudeCode, headRefOid: "a", result: result)
    #expect(old.commandLabel == "/code-review" && old.ranCodeReview) // saved before the choice existed
    old.command = ReviewCommand.generic.label(saved: [])
    #expect(old.commandLabel == nil && !old.ranCodeReview)
    var codex = AIRun(prID: "P", engine: .codex, headRefOid: "a", result: result)
    #expect(codex.commandLabel == nil)
    codex.command = "Codex review"
    #expect(codex.commandLabel == "Codex review" && !codex.ranCodeReview)
    // A Claude Code run on ReviewDesk's prompt doesn't calibrate /code-review's estimate.
    old.options = AIOptions(effort: "high")
    old.estimatedTokens = 10
    old.usage = TokenUsage(input: 100, output: 10)
    #expect(old.sample == nil)
}

@Test func codexReviewRunsItsOwnReviewReadOnlyThenStructuresTheReport() async throws {
    let structured = #"{"summary":"ok","findings":[{"severity":"high","title":"t","rationale":"r","path":"a.py","line":1,"comment":"c"}],"keyAreas":[],"risks":[]}"#
    let runner = FakeRunner { call in
        if call.args.first == "login" { return ok("Logged in using ChatGPT\n") }
        if let index = call.args.firstIndex(of: "-o") {
            let answer = call.args.contains("review") ? "[P1] Retries never stop – a.py:1" : structured
            try Data(answer.utf8).write(to: URL(fileURLWithPath: call.args[index + 1]))
        }
        return ok("")
    }
    let prompt = AIContext.codexReviewPrompt(context)
    let result = try await AIReviewer(runner: runner).codexReview(prompt: prompt, context: context,
                                                                 options: AIOptions(model: "gpt-5-codex", effort: "high"))
    #expect(result.findings.first?.path == "a.py")
    let runs = runner.calls.filter { $0.tool == "codex" && $0.args.first == "exec" }
    #expect(runs.count == 2)
    let review = runs[0].args
    #expect(Array(review.suffix(2)) == ["review", "-"])
    #expect(review[review.firstIndex(of: "--sandbox")! + 1] == "read-only")
    for flag in ["--ignore-user-config", "--ignore-rules", "--ephemeral"] { #expect(review.contains(flag)) }
    #expect(review.indices.contains { review[$0] == "--disable" && review[$0 + 1] == "hooks" })
    #expect(review.indices.contains { review[$0] == "--disable" && review[$0 + 1] == "plugins" })
    #expect(!review.contains("--output-schema") && review[review.firstIndex(of: "-c")! + 1] == "model_reasoning_effort=high")
    #expect(String(decoding: runs[0].stdin ?? Data(), as: UTF8.self).contains("never modify files"))
    // The second pass is a plain prompt with the schema, given the report.
    let structure = runs[1].args
    #expect(!structure.contains("review") && structure.contains("--output-schema") && !structure.contains("-c"))
    let second = String(decoding: runs[1].stdin ?? Data(), as: UTF8.self)
    #expect(second.contains("## Review from Codex's review\n\n[P1] Retries never stop"))
}

@Test func anEmptyCodexReviewIsAnError() async {
    let runner = FakeRunner { call in
        if call.args.first == "login" { return ok("Logged in using ChatGPT\n") }
        if let index = call.args.firstIndex(of: "-o") { try Data("  \n".utf8).write(to: URL(fileURLWithPath: call.args[index + 1])) }
        return ok("")
    }
    await #expect(throws: AIError.invalidOutput("Codex's review returned no report")) {
        try await AIReviewer(runner: runner).codexReview(prompt: "p", context: context)
    }
}
