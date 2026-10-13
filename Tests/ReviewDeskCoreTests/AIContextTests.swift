import Foundation
import Testing
@testable import ReviewDeskCore

private let pr = PullRequest(
    id: "PR_1", number: 1, title: "Fix parser", url: "", state: "OPEN", isDraft: false, updatedAt: .now,
    headRefOid: "head", headRefName: "", baseRefName: "", author: "", repo: "o/r",
    commentCount: 0, reviewCount: 0, threadCommentCount: 0, requestedReviewers: [], stack: nil
)

private let files = [
    FileChange(filename: "a.swift", status: "modified", additions: 1, deletions: 1, patch: "@@ -1,2 +1,2 @@\n ctx\n-old\n+new"),
    FileChange(filename: "logo.png", status: "added", additions: 0, deletions: 0, patch: nil),
]

private func finding(_ path: String?, _ line: Int?) -> Finding {
    Finding(severity: "high", title: "t", rationale: "r", path: path, line: line, comment: "c")
}

@Test func contextListsExclusionsAndRespectsBudget() {
    var context = AIContext.build(pr: pr, body: "desc", files: files, contents: ["a.swift": String(repeating: "x", count: 400)], budget: 50)
    #expect(context.files.map(\.included) == [true, false])
    #expect(context.files[1].excludedReason != nil)
    #expect(!context.fitsBudget)

    context.files[0].included = false
    #expect(context.fitsBudget)
    #expect(AIContext.prompt(context).contains("not provided: a.swift, logo.png"))
}

@Test func promptCarriesDiffAndFullFile() {
    let prompt = AIContext.prompt(AIContext.build(pr: pr, body: "desc", files: files, contents: ["a.swift": "ctx\nnew\n"], budget: 10_000))
    #expect(prompt.contains("## Diff: a.swift"))
    #expect(prompt.contains("## Full file at head: a.swift\n```\nctx\nnew\n"))
    #expect(prompt.contains("# Fix parser"))
}

@Test func validationKeepsOnlyAnchorableFindingsInline() {
    let result = ReviewResult(summary: "", findings: [finding("a.swift", 2), finding("a.swift", 40), finding(nil, nil), finding("ghost.swift", 1)])
    let (inline, general) = AIContext.validate(result, files: files)
    #expect(inline == [finding("a.swift", 2)])
    #expect(general.count == 3)
}

@Test func schemaIsValidJSON() throws {
    let schema = try JSONSerialization.jsonObject(with: Data(AIContext.schema.utf8)) as? [String: Any]
    #expect(schema?["required"] as? [String] == ["summary", "findings", "keyAreas", "risks"])
    let findingFields = (((schema?["properties"] as? [String: Any])?["findings"] as? [String: Any])?["items"] as? [String: Any])?["required"] as? [String]
    #expect(findingFields?.contains("suggestion") == true && findingFields?.contains("startLine") == true)
}

@Test func explainPromptMarksTheCommentAndIncludesTheDiff() {
    let first = Comment(id: "C1", author: "bob", body: "Why not a set?", createdAt: .now)
    let reply = Comment(id: "C2", author: "alice", body: "Order matters", createdAt: .now)
    let prompt = AIContext.explainPrompt(title: "T", body: "B", path: "a.swift", line: 4, patch: "@@ -1 +1 @@\n-x\n+y",
                                         conversation: [first, reply], comment: first)
    #expect(prompt.contains("## Code: a.swift, line 4"))
    #expect(prompt.contains("+y"))
    #expect(prompt.contains("**bob** **[EXPLAIN THIS]**"))
    #expect(!prompt.contains("**alice** **[EXPLAIN THIS]**"))
}

@Test func followUpsKeepTheContextAndTheChat() {
    let base = "EXPLAIN PROMPT with the diff"
    let prompt = AIContext.followUpPrompt(explainPrompt: base, chat: [
        ChatMessage(.assistant, "It asks for a set."),
        ChatMessage(.reviewer, "Why a set?"),
        ChatMessage(.assistant, "Lookups are O(1)."),
    ], question: "Would a dict work too?")
    #expect(prompt.hasPrefix(base))
    #expect(prompt.contains("**You**:\nIt asks for a set."))
    #expect(prompt.contains("**Reviewer**:\nWhy a set?"))
    #expect(prompt.contains("## The reviewer's new question\n\nWould a dict work too?"))
}

@Test func findingsThatPointAtCodeBecomeInlineComments() {
    // a.swift's diff: new lines 1-2 (context 1, added 2), old line 2 removed.
    let exact = AIContext.placement(finding("a.swift", 2), files: files)
    #expect(exact == .inline(Anchor(path: "a.swift", line: 2), startLine: nil, body: "c"))
    // A line outside the diff goes on the nearest commentable line, and says which line it meant.
    let outside = AIContext.placement(finding("a.swift", 40), files: files)
    #expect(outside == .inline(Anchor(path: "a.swift", line: 2), startLine: nil, body: "**Line 40:** c"))
    // A file-level remark goes on the file.
    #expect(AIContext.placement(finding("a.swift", nil), files: files) == .inline(Anchor(path: "a.swift", line: 1), startLine: nil, body: "**This file:** c"))
    // General remarks, files outside the PR and files without a diff go to the summary, with the reference kept.
    #expect(AIContext.placement(finding(nil, nil), files: files) == .summary("c"))
    #expect(AIContext.placement(finding("ghost.swift", 1), files: files) == .summary("`ghost.swift:1`: c"))
    #expect(AIContext.placement(finding("logo.png", 3), files: files) == .summary("`logo.png:3`: c"))
}

@Test func suggestedChangesBecomeGitHubSuggestionsOnlyWhenTheirLinesAreInTheDiff() throws {
    let twoHunks = FileChange(filename: "b.swift", status: "modified", additions: 2, deletions: 2,
                              patch: "@@ -1,1 +1,1 @@\n-a\n+b\n@@ -10,1 +10,1 @@\n-c\n+d")
    let all = files + [twoHunks]
    func fix(_ path: String, _ line: Int, from start: Int? = nil, _ code: String = "let x = 1") -> Finding {
        Finding(severity: "low", title: "t", rationale: "r", path: path, line: line, comment: "c", startLine: start, suggestion: code)
    }
    // One line, in the diff: a GitHub suggested change.
    #expect(AIContext.placement(fix("a.swift", 2), files: all) == .inline(Anchor(path: "a.swift", line: 2), startLine: nil, body: "c\n\n```suggestion\nlet x = 1\n```"))
    // Several lines, all in the diff: a multi-line suggestion starting at the first one.
    #expect(AIContext.placement(fix("a.swift", 2, from: 1), files: all) == .inline(Anchor(path: "a.swift", line: 2), startLine: 1, body: "c\n\n```suggestion\nlet x = 1\n```"))
    // Lines 2-9 aren't in the diff: a suggestion block would replace the wrong code, so it's sent as plain code.
    #expect(AIContext.placement(fix("b.swift", 10, from: 1), files: all) == .inline(Anchor(path: "b.swift", line: 10), startLine: nil, body: "c\n\nSuggested change (lines 1–10):\n```\nlet x = 1\n```"))
    // Moved to the nearest line: plain code too.
    #expect(AIContext.placement(fix("a.swift", 40), files: all) == .inline(Anchor(path: "a.swift", line: 2), startLine: nil, body: "**Line 40:** c\n\nSuggested change (line 40):\n```\nlet x = 1\n```"))
    // Unticked: the comment alone.
    #expect(AIContext.placement(fix("a.swift", 2), files: all, includeSuggestion: false) == .inline(Anchor(path: "a.swift", line: 2), startLine: nil, body: "c"))
    // Code containing a fence gets a longer one, and an empty suggestion deletes the lines.
    if case .inline(_, _, let body) = AIContext.placement(fix("a.swift", 2, "```\nx\n```"), files: all) { #expect(body.hasSuffix("````suggestion\n```\nx\n```\n````")) }
    #expect(AIContext.placement(fix("a.swift", 2, ""), files: all) == .inline(Anchor(path: "a.swift", line: 2), startLine: nil, body: "c\n\n```suggestion\n\n```"))
}

@Test func absurdLineNumbersFromTheAIAreRefusedWithoutTrapping() throws {
    let patch = "@@ -1,3 +1,4 @@\n def f(x):\n-    return x\n+    y = x\n+    return y\n end"
    let files = [FileChange(filename: "a.py", status: "modified", additions: 2, deletions: 1, patch: patch)]
    for (start, end) in [(3_000_000_000, 3_000_000_000), (Int.min, 2), (2, Int.max), (0, 1), (5, 5)] {
        #expect(throws: AIError.self) { try FixProposal(startLine: start, line: end, suggestion: "x", comment: "c").validated(patch: patch) }
        #expect(AIContext.newSideText(patch: patch, from: start, to: end) == nil)
    }
    #expect(try FixProposal(startLine: 2, line: 4, suggestion: "x", comment: "c").validated(patch: patch).line == 4)
    // Findings from a review can carry such numbers too: placement neither traps nor loops over billions of lines.
    for line in [3_000_000_000, Int.min, Int.max] {
        let finding = Finding(severity: "low", title: "t", rationale: "r", path: "a.py", line: line, comment: "c", startLine: Int.min, suggestion: "x")
        guard case .inline(let anchor, nil, _) = AIContext.placement(finding, files: files) else { Issue.record("not inline"); continue }
        #expect(anchor.side == .right)
    }
    let ranged = Finding(severity: "low", title: "t", rationale: "r", path: "a.py", line: 3, comment: "c", startLine: Int.min, suggestion: "x")
    guard case .inline(_, nil, let body) = AIContext.placement(ranged, files: files) else { Issue.record("not inline"); return }
    #expect(!body.contains("```suggestion")) // its lines can't all be in the diff: plain code
}

@Test func aFixIsAskedWithNumberedNewLinesAndPostedAsASuggestedChange() throws {
    let patch = "@@ -1,3 +1,4 @@\n def f(x):\n-    return x\n+    y = x\n+    return y\n end"
    let finding = Finding(severity: "high", title: "Off by one", rationale: "Misses the last item.", path: "a.py", line: 2, comment: "Loop to n.")
    let prompt = AIContext.fixPrompt(title: "T", body: "B", path: "a.py", patch: patch, problem: AIContext.fixProblem(finding))
    #expect(prompt.contains("    1  def f(x):\n      -    return x\n    2 +    y = x\n    3 +    return y\n    4  end"))
    #expect(prompt.contains("## [FIX THIS]\n\n**Off by one** (high), line 2") && prompt.contains(AIContext.fixSchema))
    let comment = Comment(id: "C2", author: "bob", body: "Rename y", createdAt: .now)
    #expect(AIContext.fixProblem(thread: [Comment(id: "C1", author: "amy", body: "Hm", createdAt: .now), comment], comment: comment, line: 2)
        .contains("**bob** **[THIS ONE]**:\nRename y"))

    #expect(AIContext.newSideText(patch: patch, from: 2, to: 3) == "    y = x\n    return y")
    #expect(AIContext.newSideText(patch: patch, from: 4, to: 9) == nil) // not all in the diff

    // Accepting it posts exactly like an AI finding's multi-line suggested change.
    let fix = try JSONDecoder().decode(FixProposal.self, from: Data(#"{"startLine":2,"line":3,"suggestion":"    return x","comment":"Return x directly."}"#.utf8))
    let files = [FileChange(filename: "a.py", status: "modified", additions: 2, deletions: 1, patch: patch)]
    #expect(AIContext.placement(fix.finding(path: "a.py"), files: files)
        == .inline(Anchor(path: "a.py", line: 3), startLine: 2, body: "Return x directly.\n\n```suggestion\n    return x\n```"))
    let none = FixProposal(startLine: 2, line: 2, suggestion: nil, comment: "Needs a design decision.")
    #expect(AIContext.placement(none.finding(path: "a.py"), files: files) == .inline(Anchor(path: "a.py", line: 2), startLine: nil, body: "Needs a design decision."))
}

@Test func findingsSavedBeforeSuggestionsStillLoad() throws {
    let old = try JSONDecoder().decode(Finding.self, from: Data(#"{"severity":"low","title":"t","rationale":"r","path":"a","line":1,"comment":"c"}"#.utf8))
    #expect(old.suggestion == nil && old.startLine == nil)
}
