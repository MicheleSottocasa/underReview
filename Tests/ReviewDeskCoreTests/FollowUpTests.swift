import Foundation
import Testing
@testable import ReviewDeskCore

private func comment(_ id: String, _ author: String, _ body: String) -> ReviewDeskCore.Comment {
    ReviewDeskCore.Comment(id: id, author: author, body: body, createdAt: .now, kind: .review)
}

private let mine = ReviewThread(id: "T1", path: "a.py", line: 4, side: .right, isResolved: false, isOutdated: true,
                                comments: [comment("C1", "me", "Please scope this query."), comment("C2", "bob", "Done in 3f2a.")])
private let waiting = ReviewThread(id: "T2", path: "b.py", line: 9, side: .right, isResolved: false, isOutdated: false,
                                   comments: [comment("C3", "me", "Add a test?")])
private let resolved = ReviewThread(id: "T3", path: "c.py", line: 1, side: .right, isResolved: true, isOutdated: false,
                                    comments: [comment("C4", "me", "Typo"), comment("C5", "bob", "Fixed")])
private let others = ReviewThread(id: "T4", path: "d.py", line: 2, side: .right, isResolved: false, isOutdated: false,
                                  comments: [comment("C6", "eve", "Nit"), comment("C7", "bob", "ok")])
private let detail = PRDetail(body: "", comments: [], reviews: [Review(id: "R1", author: "me", state: "CHANGES_REQUESTED", body: "Also rename the flag.", submittedAt: .now)],
                              threads: [mine, waiting, resolved, others], pendingReview: nil)

private func pr(head: String = "new", reviewed: String? = "old") -> PullRequest {
    var pr = PullRequest(id: "PR_1", number: 1, title: "T", url: "", state: "OPEN", isDraft: false, updatedAt: .now, headRefOid: head,
                         headRefName: "", baseRefName: "", author: "bob", repo: "o/r", commentCount: 0, reviewCount: 1,
                         threadCommentCount: 0, requestedReviewers: [], stack: nil)
    pr.viewerReviewState = "CHANGES_REQUESTED"
    pr.viewerReviewedOid = reviewed
    return pr
}

@Test func followUpLooksAtTheViewersOpenThreads() {
    #expect(FollowUp.threads(of: "me", in: detail).map(\.id) == ["T1", "T2"]) // not resolved ones, not others'
    #expect(FollowUp.replies(to: "me", in: detail) == 1)                     // only T1 has a reply after mine
    #expect(FollowUp.reviewBodies(of: "me", in: detail) == ["Also rename the flag."])
}

@Test func followUpIsDueAfterNewCommitsOrReplies() {
    #expect(FollowUp.isDue(pr(head: "new", reviewed: "old"), detail: detail, viewer: "me"))
    #expect(FollowUp.isDue(pr(head: "same", reviewed: "same"), detail: detail, viewer: "me")) // a reply is enough
    let quiet = PRDetail(body: "", comments: [], reviews: [], threads: [waiting], pendingReview: nil)
    #expect(!FollowUp.isDue(pr(head: "same", reviewed: "same"), detail: quiet, viewer: "me"))
    #expect(!FollowUp.isDue(pr(), detail: detail, viewer: "someone-else"))                   // no requests of theirs
}

@Test func followUpPromptCarriesRequestsRepliesAndChanges() throws {
    let changes = ReviewContext(title: "T", body: "", files: [ContextFile(path: "a.py", patch: "@@ -1 +1 @@\n+scoped", content: nil, included: true)], budget: 1000)
    let since = FollowUp.prompt(title: "T", viewer: "me", threads: [mine], reviewBodies: ["Also rename the flag."], changes: changes, sinceReview: true)
    #expect(since.contains("### Thread T1: a.py, line 4 (the code it pointed at has changed)"))
    #expect(since.contains("**bob**:\nDone in 3f2a."))
    #expect(since.contains("## The reviewer's review summary\n\nAlso rename the flag."))
    #expect(since.contains("## Changes since the reviewer's review") && since.contains("+scoped"))
    let whole = FollowUp.prompt(title: "T", viewer: "me", threads: [mine], reviewBodies: [], changes: changes, sinceReview: false)
    #expect(whole.contains("so this is the full diff"))
    let schema = try #require(try JSONSerialization.jsonObject(with: Data(FollowUp.schema.utf8)) as? [String: Any])
    #expect(schema["required"] as? [String] == ["summary", "items"])
    let result = try JSONDecoder().decode(FollowUpResult.self, from: Data(#"{"summary":"One left.","items":[{"threadID":"T1","request":"Scope the query","status":"addressed","explanation":"a.py:4 now filters by org."},{"threadID":null,"request":"Rename the flag","status":"not_addressed","explanation":"Still --old."}]}"#.utf8))
    #expect(result.items.map(\.status) == ["addressed", "not_addressed"] && result.items[1].threadID == nil)
}

@Test func compareReturnsTheChangedFilesWithPatches() async throws {
    let runner = FakeRunner { _ in ok(#"{"status":"ahead","files":[{"filename":"a.py","status":"modified","additions":1,"deletions":0,"patch":"@@ -1 +1 @@\n+x"}]}"#) }
    let files = try await GitHub(runner: runner).compareFiles(repo: "o/r", from: "old", to: "new")
    #expect(files.map(\.filename) == ["a.py"] && files[0].patch?.contains("+x") == true)
    #expect(runner.calls.first?.args == ["api", "repos/o/r/compare/old...new", "--jq", "{status, files}"])
}

@Test func compareRefusesCommitsFromARewrittenHistory() async throws {
    // After a rebase GitHub still answers, from the merge base: the diff would include the base branch's changes.
    let runner = FakeRunner { _ in ok(#"{"status":"diverged","files":[{"filename":"upstream.py","status":"modified","additions":9,"deletions":0}]}"#) }
    await #expect(throws: GitHubError.rewritten) { try await GitHub(runner: runner).compareFiles(repo: "o/r", from: "old", to: "new") }
    let same = FakeRunner { _ in ok(#"{"status":"identical","files":[]}"#) }
    #expect(try await GitHub(runner: same).compareFiles(repo: "o/r", from: "a", to: "a").isEmpty)
}
