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
    #expect(schema?["required"] as? [String] == ["summary", "findings", "keyAreas"])
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
