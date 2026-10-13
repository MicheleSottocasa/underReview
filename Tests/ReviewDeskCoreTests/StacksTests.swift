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
    var mine = pr("A", 1, stack: 1, entries: ["A", "B"])
    mine.viewerIsAuthor = true
    let items = Stacks.items([mine, pr("B", 2, stack: 1, entries: ["A", "B"]), pr("solo", 3)])
    #expect(items.filter(\.isViewers).map(\.key) == ["stack:o/r#1"]) // one PR of the stack is enough
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
