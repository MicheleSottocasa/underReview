import Foundation
import Testing
@testable import ReviewDeskCore

private func pr(_ id: String, _ number: Int, stack: Int? = nil, entries: [String] = [], updated: TimeInterval = 0) -> PullRequest {
    PullRequest(
        id: id, number: number, title: "", url: "", state: "OPEN", isDraft: false,
        updatedAt: Date(timeIntervalSince1970: updated), headRefOid: "", headRefName: "", baseRefName: "",
        author: "", repo: "o/r", commentCount: 0, reviewCount: 0, threadCommentCount: 0, requestedReviewers: [],
        stack: stack.map { StackInfo(number: $0, entries: entries.enumerated().map { .init(position: $0 + 1, id: $1, number: 0) }) }
    )
}

@Test func groupsStacksInPositionOrder() {
    let entries = ["A", "B", "C"]
    let items = Stacks.items([
        pr("C", 30, stack: 1, entries: entries, updated: 5),
        pr("solo", 9, updated: 1),
        pr("A", 10, stack: 1, entries: entries, updated: 2),
        pr("B", 20, stack: 1, entries: entries, updated: 3),
    ])
    #expect(items.map(\.key) == ["stack:o/r#1", "pr:solo"])
    #expect(items[0].pullRequests.map(\.id) == ["A", "B", "C"])
    #expect(items[0].isStack && !items[1].isStack)
}

@Test func itemsTheViewerWroteAreTheirs() {
    // My merged bottom PR makes the whole stack mine, even with merged PRs filtered out of the sidebar.
    var mine = pr("A", 1, stack: 1, entries: ["A", "B"])
    mine.viewerIsAuthor = true
    mine.state = "MERGED"
    var standalone = pr("own", 4)
    standalone.viewerIsAuthor = true
    let keys = Stacks.viewersItemKeys([mine, pr("B", 2, stack: 1, entries: ["A", "B"]), pr("solo", 3), standalone])
    #expect(keys == ["stack:o/r#1", "pr:own"])
}

@Test func mergedBottomPRStaysInStack() {
    var bottom = pr("A", 1, stack: 1, entries: ["A", "B"])
    bottom.state = "MERGED"
    let items = Stacks.items([bottom, pr("B", 2, stack: 1, entries: ["A", "B"])])
    #expect(items.count == 1)
    #expect(items[0].pullRequests.map(\.state) == ["MERGED", "OPEN"])
}

@Test func findsStackMembersNotYetFollowed() {
    #expect(Stacks.missingMembers(of: [pr("B", 2, stack: 1, entries: ["A", "B", "C"]), pr("x", 3)]) == ["A", "C"])
}

@Test func orderIsStableAcrossUpdates() {
    var a = pr("A", 5, updated: 100), b = pr("B", 9, updated: 1)
    b.repo = "o/a"
    let first = Stacks.items([a, b]).map(\.key)
    a.updatedAt = .distantPast
    #expect(first == ["pr:B", "pr:A"]) // repo o/a before o/r
    #expect(Stacks.items([a, b]).map(\.key) == first)
}

@Test func stackRunsSkipClosedAndApprovedPullRequests() {
    func pr(_ id: String, state: String = "OPEN", review: String? = nil) -> PullRequest {
        var pr = PullRequest(id: id, number: 1, title: "", url: "", state: state, isDraft: false, updatedAt: .now, headRefOid: "h",
                             headRefName: "", baseRefName: "", author: "", repo: "o/r", commentCount: 0, reviewCount: 0,
                             threadCommentCount: 0, requestedReviewers: [], stack: nil)
        pr.viewerReviewState = review
        return pr
    }
    let stack = [pr("A", review: "APPROVED"), pr("B", review: "CHANGES_REQUESTED"), pr("C", state: "MERGED"), pr("D"), pr("E", review: "COMMENTED")]
    #expect(Stacks.toReview(stack).map(\.id) == ["B", "D", "E"])
}

@Test func stepsToTheNeighboursInTheStack() throws {
    let stack = try #require(pr("B", 20, stack: 1, entries: ["A", "B", "C"]).stack)
    #expect(stack.neighbors(of: "A").below == nil && stack.neighbors(of: "A").above?.id == "B")
    #expect(stack.neighbors(of: "B").below?.id == "A" && stack.neighbors(of: "B").above?.id == "C")
    #expect(stack.neighbors(of: "C").above == nil)
    #expect(stack.neighbors(of: "gone").below == nil && stack.neighbors(of: "gone").above == nil)
}

@Test func reviewedItemsWaitForNothing() {
    func reviewed(_ id: String, _ number: Int, stack: Int? = nil, entries: [String] = []) -> PullRequest {
        var reviewed = pr(id, number, stack: stack, entries: entries)
        reviewed.viewerReviewState = "APPROVED"
        reviewed.viewerReviewedOid = reviewed.headRefOid
        return reviewed
    }
    var reRequested = reviewed("again", 2)
    reRequested.requestedReviewers = ["me"]
    var pushed = reviewed("pushed", 3)
    pushed.headRefOid = "new"
    var merged = pr("merged", 4)
    merged.state = "MERGED"
    // One member still waiting keeps the whole stack in To Review; a fully reviewed stack moves.
    let waitingStack = [reviewed("A", 5, stack: 1, entries: ["A", "B"]), pr("B", 6, stack: 1, entries: ["A", "B"])]
    let doneStack = [reviewed("C", 7, stack: 2, entries: ["C", "D"]), reviewed("D", 8, stack: 2, entries: ["C", "D"])]
    let all = [reviewed("done", 1), reRequested, pushed, merged, pr("new", 9)] + waitingStack + doneStack
    #expect(Stacks.reviewedItemKeys(all) { _ in "me" } == ["pr:done", "pr:merged", "stack:o/r#2"])
}
