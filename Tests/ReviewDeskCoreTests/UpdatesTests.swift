import Foundation
import Testing
@testable import ReviewDeskCore

private func pr(head: String = "a", state: String = "OPEN", comments: Int = 0, reviews: Int = 0, replies: Int = 0, requested: [String] = [],
                mine: Bool = false, mergeable: String? = "MERGEABLE") -> PullRequest {
    var pr = PullRequest(
        id: "PR_1", number: 1, title: "", url: "", state: state, isDraft: false, updatedAt: .now,
        headRefOid: head, headRefName: "", baseRefName: "", author: "", repo: "o/r",
        commentCount: comments, reviewCount: reviews, threadCommentCount: replies, requestedReviewers: requested, stack: nil
    )
    (pr.viewerIsAuthor, pr.mergeable) = (mine, mergeable)
    return pr
}

@Test func notifiesOnceWhenMyPullRequestStartsToConflict() throws {
    var checkpoints: [String: Snapshot] = [:]
    _ = Updates.advance(&checkpoints, with: [pr(mine: true)], viewer: "me")
    // GitHub is still computing: nothing yet, and the next poll asks again.
    #expect(Updates.advance(&checkpoints, with: [pr(mine: true, mergeable: "UNKNOWN")], viewer: "me").isEmpty)
    #expect(Updates.advance(&checkpoints, with: [pr(mine: true, mergeable: "CONFLICTING")], viewer: "me") == ["PR_1": [.conflicts]])
    // Unknown again, then still conflicting: not a new conflict.
    #expect(Updates.advance(&checkpoints, with: [pr(mine: true, mergeable: "UNKNOWN")], viewer: "me").isEmpty)
    #expect(Updates.advance(&checkpoints, with: [pr(mine: true, mergeable: "CONFLICTING")], viewer: "me").isEmpty)
    // Someone else's PR, or a checkpoint saved before conflicts were tracked: no notification.
    var others: [String: Snapshot] = [:]
    _ = Updates.advance(&others, with: [pr()], viewer: "me")
    #expect(Updates.advance(&others, with: [pr(mergeable: "CONFLICTING")], viewer: "me").isEmpty)
    let legacy = try JSONDecoder().decode(Snapshot.self, from: Data(#"""
    {"headRefOid":"a","state":"OPEN","commentCount":0,"reviewCount":0,"threadCommentCount":0,"reviewRequested":false}
    """#.utf8))
    var upgraded = ["PR_1": legacy]
    #expect(Updates.advance(&upgraded, with: [pr(mine: true, mergeable: "CONFLICTING")], viewer: "me").isEmpty)
}

@Test func myOwnWriteDoesNotSwallowANewConflict() {
    var checkpoints: [String: Snapshot] = [:]
    _ = Updates.advance(&checkpoints, with: [pr(mine: true)], viewer: "me")
    // I comment; the re-read PR already conflicts. The comment is acknowledged, the conflict is still news.
    Updates.acknowledgeOwnWrite(&checkpoints, pr: pr(comments: 1, mine: true, mergeable: "CONFLICTING"), viewer: "me")
    #expect(checkpoints["PR_1"]?.commentCount == 1)
    #expect(Updates.advance(&checkpoints, with: [pr(comments: 1, mine: true, mergeable: "CONFLICTING")], viewer: "me") == ["PR_1": [.conflicts]])
}

@Test func refetchesPullRequestsWhoseMergeabilityIsUnknown() {
    let unknown = pr(mergeable: "UNKNOWN")
    #expect(Updates.changed(["PR_1": unknown.updatedAt], cached: ["PR_1": unknown]) == ["PR_1"])
    var merged = unknown
    merged.state = "MERGED"
    #expect(Updates.changed(["PR_1": merged.updatedAt], cached: ["PR_1": merged]).isEmpty)
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

@Test func customPollIntervalsKeepAFloorAndBackOff() {
    #expect(Updates.interval(foreground: true, failures: 0, foregroundSeconds: 90) == .seconds(90))
    #expect(Updates.interval(foreground: false, failures: 0, backgroundSeconds: 5) == .seconds(60)) // floor protects the rate limit
    #expect(Updates.interval(foreground: false, failures: 9, backgroundSeconds: 3600) == .seconds(3600)) // cap never undercuts the base
}
