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

@Test func findingsSavedBeforeSuggestionsStillLoad() throws {
    let old = try JSONDecoder().decode(Finding.self, from: Data(#"{"severity":"low","title":"t","rationale":"r","path":"a","line":1,"comment":"c"}"#.utf8))
    #expect(old.suggestion == nil && old.startLine == nil)
}
