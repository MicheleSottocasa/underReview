import Foundation
import Testing
@testable import ReviewDeskCore

private func pr(head: String = "a", state: String = "OPEN", comments: Int = 0, reviews: Int = 0, replies: Int = 0, requested: [String] = []) -> PullRequest {
    PullRequest(
        id: "PR_1", number: 1, title: "", url: "", state: state, isDraft: false, updatedAt: .now,
        headRefOid: head, headRefName: "", baseRefName: "", author: "", repo: "o/r",
        commentCount: comments, reviewCount: reviews, threadCommentCount: replies, requestedReviewers: requested, stack: nil
    )
}

@Test func firstLoadProducesNoEvents() {
    var checkpoints: [String: Snapshot] = [:]
    #expect(Updates.advance(&checkpoints, with: [pr(comments: 5)], viewer: "me").isEmpty)
    #expect(checkpoints["PR_1"]?.commentCount == 5)
}

@Test func pushAndReplyAreDistinctEventsAndNotRepeated() {
    var checkpoints: [String: Snapshot] = [:]
    _ = Updates.advance(&checkpoints, with: [pr()], viewer: "me")

    let events = Updates.advance(&checkpoints, with: [pr(head: "b", replies: 1)], viewer: "me")
    #expect(events == ["PR_1": [.newCommits, .newReplies(1)]])

    #expect(Updates.advance(&checkpoints, with: [pr(head: "b", replies: 1)], viewer: "me").isEmpty)
}

@Test func offlineGapCollapsesIntoOneGroupPerPR() {
    var checkpoints: [String: Snapshot] = [:]
    _ = Updates.advance(&checkpoints, with: [pr()], viewer: "me")
    let events = Updates.advance(&checkpoints, with: [pr(state: "MERGED", comments: 3, reviews: 2, requested: ["me"])], viewer: "me")
    #expect(events["PR_1"] == [.stateChanged("MERGED"), .newComments(3), .newReviews(2), .reviewRequested])
}

@Test func reviewRequestOnlyCountsForViewer() {
    var checkpoints: [String: Snapshot] = [:]
    _ = Updates.advance(&checkpoints, with: [pr()], viewer: "me")
    #expect(Updates.advance(&checkpoints, with: [pr(requested: ["someone"])], viewer: "me").isEmpty)
}

@Test func backoffDoublesAndCaps() {
    #expect(Updates.interval(foreground: true, failures: 0) == .seconds(180))
    #expect(Updates.interval(foreground: false, failures: 0) == .seconds(600))
    #expect(Updates.interval(foreground: true, failures: 2) == .seconds(720))
    #expect(Updates.interval(foreground: true, failures: 50) == .seconds(1800))
}

@Test func onlyNewOrUpdatedPRsNeedAFullFetch() {
    let cached = pr()
    let later = cached.updatedAt.addingTimeInterval(60)
    #expect(Updates.changed(["PR_1": cached.updatedAt], cached: ["PR_1": cached]).isEmpty)
    #expect(Updates.changed(["PR_1": later, "PR_2": later], cached: ["PR_1": cached]) == ["PR_1", "PR_2"])
}
