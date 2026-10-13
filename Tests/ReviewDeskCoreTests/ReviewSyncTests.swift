import Foundation
import Testing
@testable import ReviewDeskCore

private let pr = PullRequest(
    id: "PR_1", number: 1, title: "", url: "", state: "OPEN", isDraft: false, updatedAt: .now,
    headRefOid: "head", headRefName: "", baseRefName: "", author: "", repo: "o/r",
    commentCount: 0, reviewCount: 0, threadCommentCount: 0, requestedReviewers: [], stack: nil
)

private func detail(pending: String = "[]") -> CommandResult {
    data(#"{"node":{"body":"","comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]},"pending":{"nodes":\#(pending)}}}"#)
}

private func pendingWith(_ comments: String) -> String {
    #"[{"id":"REV","commit":{"oid":"head"},"comments":{"nodes":\#(comments)}}]"#
}

private func draft(_ body: String, line: Int = 5) -> Draft {
    Draft(prID: "PR_1", anchor: Anchor(path: "a.swift", line: line), body: body, commitOID: "head")
}

private let threadCreated = data(#"{"addPullRequestReviewThread":{"thread":{"comments":{"nodes":[{"id":"NEW"}]}}}}"#)

/// Mutable state shared with a FakeRunner closure.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Test func saveCreatesPendingReviewWhenNoneExists() async throws {
    let runner = FakeRunner { call in
        if call.query.contains("addPullRequestReview(") { return data(#"{"addPullRequestReview":{"pullRequestReview":{"id":"REV"}}}"#) }
        if call.query.contains("addPullRequestReviewThread(") { return threadCreated }
        return detail()
    }
    let saved = try await ReviewSync(github: GitHub(runner: runner)).save([draft("nit")], pr: pr)

    #expect(saved.map(\.remoteID) == ["NEW"])
    #expect(!saved[0].needsSync)
    let create = try #require(runner.calls.first { $0.query.contains("addPullRequestReview(") })
    #expect(create.variables["event"] == nil)
    #expect(create.variables["oid"] as? String == "head")
    #expect(runner.calls.first { $0.query.contains("addPullRequestReviewThread(") }?.variables["review"] as? String == "REV")
}

@Test func saveReusesExistingPendingReviewAndKeepsWebComments() async throws {
    let runner = FakeRunner { call in
        if call.query.contains("addPullRequestReviewThread(") { return threadCreated }
        if call.query.contains("mutation") { Issue.record("unexpected write: \(call.query)") }
        return detail(pending: pendingWith(#"[{"id":"WEB","path":"z.swift","line":1,"body":"from web"},{"id":"SAME","path":"a.swift","line":9,"body":"already there"}]"#))
    }
    let saved = try await ReviewSync(github: GitHub(runner: runner)).save([draft("new"), draft("already there", line: 9)], pr: pr)

    #expect(saved.map(\.remoteID) == ["NEW", "SAME"])
    #expect(runner.calls.filter { $0.query.contains("mutation") }.count == 1)
}

@Test func saveUpdatesEditedDraftsInPlace() async throws {
    var edited = draft("v2")
    edited.remoteID = "C1"
    edited.syncedBody = "v1"
    let runner = FakeRunner { call in
        if call.query.contains("updatePullRequestReviewComment") { return data(#"{"updatePullRequestReviewComment":{}}"#) }
        return detail(pending: pendingWith(#"[{"id":"C1","path":"a.swift","line":5,"body":"v1"}]"#))
    }
    let saved = try await ReviewSync(github: GitHub(runner: runner)).save([edited], pr: pr)

    #expect(saved[0].syncedBody == "v2")
    #expect(runner.calls.last?.variables["body"] as? String == "v2")
}

@Test func timeoutDuringWriteReconcilesInsteadOfDuplicating() async throws {
    let landed = Box(false)
    let runner = FakeRunner { call in
        if call.query.contains("addPullRequestReviewThread(") {
            landed.value = true
            throw CommandError.timedOut("gh") // the write reached GitHub but the response was lost
        }
        return detail(pending: pendingWith(landed.value ? #"[{"id":"LANDED","path":"a.swift","line":5,"body":"nit"}]"# : "[]"))
    }
    let saved = try await ReviewSync(github: GitHub(runner: runner)).save([draft("nit")], pr: pr)

    #expect(saved[0].remoteID == "LANDED")
    #expect(runner.calls.filter { $0.query.contains("addPullRequestReviewThread(") }.count == 1)
}

@Test func staleDraftsBlockSaving() async {
    var stale = draft("x")
    stale.isStale = true
    let runner = FakeRunner { _ in detail() }
    await #expect(throws: ReviewSyncError.staleDrafts(1)) {
        try await ReviewSync(github: GitHub(runner: runner)).save([stale], pr: pr)
    }
    #expect(runner.calls.isEmpty)
}

@Test func refreshStalenessOnlyFlagsDraftsWhoseFileChanged() async {
    let runner = FakeRunner { call in
        #expect(call.args.contains("repos/o/r/compare/old...head"))
        return ok(#"["a.swift"]"#)
    }
    var touched = draft("x"), untouched = Draft(prID: "PR_1", anchor: Anchor(path: "b.swift", line: 1), body: "y", commitOID: "old")
    touched.commitOID = "old"
    let result = await ReviewSync(github: GitHub(runner: runner)).refreshStaleness([touched, untouched], pr: pr)

    #expect(result.map(\.isStale) == [true, false])
    #expect(result[1].commitOID == "head")
    #expect(runner.calls.count == 1)
}

@Test func publishSubmitsPendingReviewWithChosenEvent() async throws {
    let runner = FakeRunner { call in
        if call.query.contains("submitPullRequestReview") { return data(#"{"submitPullRequestReview":{}}"#) }
        return detail(pending: pendingWith("[]"))
    }
    try await ReviewSync(github: GitHub(runner: runner)).publish(pr: pr, event: .requestChanges, body: "see inline", viewer: "me")

    let submit = try #require(runner.calls.last)
    #expect(submit.variables["id"] as? String == "REV")
    #expect(submit.variables["event"] as? String == "REQUEST_CHANGES")
}

@Test func publishWithoutPendingReviewCreatesSubmittedReview() async throws {
    let runner = FakeRunner { call in
        if call.query.contains("addPullRequestReview(") { return data(#"{"addPullRequestReview":{"pullRequestReview":{"id":"R"}}}"#) }
        return detail()
    }
    try await ReviewSync(github: GitHub(runner: runner)).publish(pr: pr, event: .approve, body: "", viewer: "me")
    #expect(runner.calls.last?.variables["event"] as? String == "APPROVE")
}

@Test func publishTimeoutIsNotRetriedWhenReviewWasSubmitted() async throws {
    let submitted = Box(false)
    let runner = FakeRunner { call in
        if call.query.contains("submitPullRequestReview") {
            submitted.value = true
            throw CommandError.timedOut("gh")
        }
        return detail(pending: submitted.value ? "[]" : pendingWith("[]"))
    }
    try await ReviewSync(github: GitHub(runner: runner)).publish(pr: pr, event: .comment, body: "", viewer: "me")
    #expect(runner.calls.filter { $0.query.contains("submitPullRequestReview") }.count == 1)
}

@Test func deletingAlreadyRemovedCommentIsHarmless() async throws {
    var saved = draft("x")
    saved.remoteID = "GONE"
    let runner = FakeRunner { _ in CommandResult(status: 1, stdout: Data(#"{"errors":[{"message":"Could not resolve to a node"}]}"#.utf8)) }
    try await ReviewSync(github: GitHub(runner: runner)).delete(saved)
    try await ReviewSync(github: GitHub(runner: runner)).delete(draft("local only"))
    #expect(runner.calls.count == 1)
}

@Test func multiLineDraftsSendWhereTheyStart() {
    let sync = ReviewSync(github: GitHub(runner: FakeRunner { _ in ok("") }))
    var draft = Draft(prID: "PR_1", anchor: Anchor(path: "a.swift", line: 12), body: "b", commitOID: "head")
    #expect(sync.variables(draft, review: "R")["startLine"] == nil) // one line: GitHub's default
    draft.startLine = 9
    let range = sync.variables(draft, review: "R")
    #expect(range["startLine"] as? Int == 9 && range["startSide"] as? String == "RIGHT" && range["line"] as? Int == 12)
}

@Test func ownPullRequestsOnlyAllowCommentReviews() {
    var mine = pr
    mine.viewerIsAuthor = true
    #expect(ReviewEvent.allowed(for: mine) == [.comment])
    #expect(ReviewEvent.allowed(for: pr) == [.comment, .approve, .requestChanges])
}
