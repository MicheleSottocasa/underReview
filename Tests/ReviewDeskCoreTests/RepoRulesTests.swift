import Foundation
import Testing
@testable import ReviewDeskCore

@Test func looksForRootAndNestedRules() {
    let candidates = RepoRules.candidates(changed: ["app/api/views.py", "app/models.py", "README.md"])
    #expect(Array(candidates.prefix(RepoRules.rootFiles.count)) == RepoRules.rootFiles)
    #expect(Array(candidates.dropFirst(RepoRules.rootFiles.count)) == ["app/AGENTS.md", "app/CLAUDE.md", "app/api/AGENTS.md", "app/api/CLAUDE.md"])
}

@Test func rulesKeepCandidateOrderAndStateCuts() {
    let long = String(repeating: "x", count: RepoRules.maxCharacters + 5)
    let rules = RepoRules.contextFiles(["app/AGENTS.md": "nested", "AGENTS.md": "root", "CLAUDE.md": "  ", "CONTRIBUTING.md": long],
                                       changed: ["app/a.py"])
    #expect(rules.map(\.path) == ["AGENTS.md", "CONTRIBUTING.md", "app/AGENTS.md"]) // empty CLAUDE.md skipped
    #expect(rules[1].content?.hasSuffix("[ReviewDesk cut this file at 20000 of 20005 characters.]") == true)
}

@Test func reviewPromptsCarryTheRules() throws {
    let pr = PullRequest(id: "PR_1", number: 1, title: "T", url: "https://github.com/o/r/pull/1", state: "OPEN", isDraft: false,
                         updatedAt: .now, headRefOid: "h", headRefName: "", baseRefName: "main", author: "", repo: "o/r",
                         commentCount: 0, reviewCount: 0, threadCommentCount: 0, requestedReviewers: [], stack: nil)
    let files = [FileChange(filename: "a.py", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1 @@\n+x")]
    var context = AIContext.build(pr: pr, body: "", files: files, contents: [:], budget: 10_000, rules: ["AGENTS.md": "Never use print()."])
    #expect(AIContext.prompt(context).contains("### AGENTS.md\n\nNever use print()."))
    #expect(AIContext.structurePrompt(report: "r", context: context).contains("Never use print()."))
    // Rules count toward the budget and survive trimming; deselected ones aren't sent.
    #expect(context.tokens > AIContext.build(pr: pr, body: "", files: files, contents: [:], budget: 10_000).tokens)
    context.budget = context.rules[0].tokens + 2
    #expect(context.fittingBudget().rules[0].included)
    context.rules[0].included = false
    #expect(!AIContext.prompt(context).contains("Never use print()."))
}

@Test func codeReviewChecksTheRulesInTheStructuringPass() async throws {
    let runner = FakeRunner { call in
        if call.args.first == "auth" { return ok(#"{"loggedIn":true,"authMethod":"claude.ai"}"#) }
        if call.args.contains("--json-schema") {
            return ok(#"{"type":"result","is_error":false,"structured_output":{"summary":"ok","findings":[],"keyAreas":[],"risks":[]}}"#)
        }
        return ok(diffReadEvents + "\n" + #"{"type":"result","is_error":false,"result":"No problems."}"#)
    }
    let rules = RepoRules.contextFiles(["AGENTS.md": "Every endpoint needs a permission check."], changed: [])
    let context = ReviewContext(title: "T", body: "", files: [], budget: 1000, rules: rules)
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("rd-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: config) }
    _ = try await AIReviewer(runner: runner, claudeConfigDirectory: config).codeReview(.claudeCode, prURL: "u", context: context, options: AIOptions())
    let structure = try #require(runner.calls.last { $0.args.contains("--json-schema") })
    #expect(String(decoding: structure.stdin ?? Data(), as: UTF8.self).contains("Every endpoint needs a permission check."))
}
