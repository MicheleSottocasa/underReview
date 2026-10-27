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

@Test func itemsDoneForLongerThanTheSettingAge() {
    let now = Date(timeIntervalSince1970: 10 * 86_400)
    func done(_ id: String, _ number: Int, state: String = "MERGED", daysAgo: Double, stack: Int? = nil, entries: [String] = []) -> PullRequest {
        var pr = pr(id, number, stack: stack, entries: entries, updated: now.timeIntervalSince1970)
        pr.state = state
        pr.closedAt = now.addingTimeInterval(-daysAgo * 86_400)
        return pr
    }
    var cached = pr("cached", 5, updated: now.timeIntervalSince1970 - 3 * 86_400)
    cached.state = "CLOSED" // cached before closedAt was read: its update time counts
    let prs = [
        done("old", 1, daysAgo: 2), done("fresh", 2, daysAgo: 0.5), done("closed", 3, state: "CLOSED", daysAgo: 1.5), pr("open", 4), cached,
        // A stack moves only once every member is done, counted from the last one.
        done("A", 6, daysAgo: 5, stack: 1, entries: ["A", "B"]), pr("B", 7, stack: 1, entries: ["A", "B"]),
        done("C", 8, daysAgo: 5, stack: 2, entries: ["C", "D"]), done("D", 9, daysAgo: 0.2, stack: 2, entries: ["C", "D"]),
        done("E", 10, daysAgo: 5, stack: 3, entries: ["E", "F"]), done("F", 11, state: "CLOSED", daysAgo: 3, stack: 3, entries: ["E", "F"]),
    ]
    #expect(Stacks.agedItemKeys(prs, now: now, afterDays: 1) == ["pr:old", "pr:closed", "pr:cached", "stack:o/r#3"])
    #expect(Stacks.agedItemKeys(prs, now: now, afterDays: 2) == ["pr:cached", "stack:o/r#3"])
    #expect(Stacks.agedItemKeys(prs, now: now, afterDays: 0).isEmpty)
}
