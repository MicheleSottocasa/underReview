import Foundation
import Testing
@testable import ReviewDeskCore

private func at(_ minute: Double) -> Date { Date(timeIntervalSince1970: minute * 60) }

private func comment(_ id: String, _ author: String, _ minute: Double, review: String? = nil) -> ReviewDeskCore.Comment {
    ReviewDeskCore.Comment(id: id, author: author, body: id, createdAt: at(minute), kind: review == nil ? .issue : .review, reviewID: review)
}

private func thread(_ id: String, resolved: Bool = false, _ comments: [ReviewDeskCore.Comment]) -> ReviewThread {
    ReviewThread(id: id, path: "a.swift", line: 3, side: .right, isResolved: resolved, isOutdated: false, comments: comments)
}

private let detail = PRDetail(
    body: "",
    comments: [comment("IC_bob", "bob", 1), comment("IC_me", "me", 6)],
    reviews: [Review(id: "R_me", author: "me", state: "COMMENTED", body: "", submittedAt: at(2)),
              Review(id: "R_me_reply", author: "me", state: "COMMENTED", body: "", submittedAt: at(7)), // C2, a reply
              Review(id: "R_bob", author: "bob", state: "APPROVED", body: "ok", submittedAt: at(5))],
    threads: [
        thread("T_bob", [comment("C1", "bob", 4.5, review: "R_bob"), comment("C2", "me", 7, review: "R_me_reply")]),
        thread("T_me_done", resolved: true, [comment("C3", "me", 1.9, review: "R_me")]),
        thread("T_me", [comment("C4", "me", 1.8, review: "R_me"), comment("C5", "bob", 3)]),
        thread("T_pending", [comment("C6", "me", 8, review: "R_pending")]), // the pending review isn't listed
    ],
    pendingReview: nil)

private func ids(_ items: [Conversation.Item]) -> [String] {
    items.map { item in
        if case .review(_, let threads) = item { return "\(item.id)[\(threads.map(\.id).joined(separator: ","))]" }
        return item.id
    }
}

@Test func conversationPutsThreadsUnderTheirReviewInDateOrder() {
    #expect(ids(Conversation.timeline(detail, viewer: "me", filter: .all))
            == ["IC_bob", "R_me[T_me,T_me_done]", "R_bob[T_bob]", "IC_me", "R_me_reply[]", "T_pending"])
}

@Test func conversationFiltersThreadsTheViewerStarted() {
    // My comments and reviews, my threads; not bob's thread even though I replied in it, nor the empty review
    // GitHub made for that reply.
    #expect(ids(Conversation.timeline(detail, viewer: "me", filter: .startedByMe)) == ["R_me[T_me,T_me_done]", "IC_me", "T_pending"])
    #expect(ids(Conversation.timeline(detail, viewer: "bob", filter: .startedByMe)) == ["IC_bob", "R_bob[T_bob]"])
}

@Test func conversationFiltersUnresolvedThreads() {
    #expect(ids(Conversation.timeline(detail, viewer: "me", filter: .unresolved)) == ["R_me[T_me]", "R_bob[T_bob]", "T_pending"])
}

@Test func conversationFiltersWhatInvolvesTheViewer() {
    // Bob's thread because I replied in it, under bob's review; not the empty review GitHub made for my reply.
    #expect(ids(Conversation.timeline(detail, viewer: "me", filter: .involvingMe))
            == ["R_me[T_me,T_me_done]", "R_bob[T_bob]", "IC_me", "T_pending"])
    // My thread bob replied in, under my review, which is shown for it.
    #expect(ids(Conversation.timeline(detail, viewer: "bob", filter: .involvingMe)) == ["IC_bob", "R_me[T_me]", "R_bob[T_bob]"])
}

@Test func conversationInvolvingMeIncludesMentions() {
    func said(_ id: String, _ body: String, _ minute: Double, review: String? = nil) -> ReviewDeskCore.Comment {
        var said = comment(id, "ann", minute, review: review)
        said.body = body
        return said
    }
    let mentions = PRDetail(
        body: "",
        comments: [said("IC_cc", "cc @Me", 1), said("IC_other", "mail me@x.io", 2)],
        reviews: [Review(id: "R_cc", author: "ann", state: "COMMENTED", body: "@me ptal", submittedAt: at(3)),
                  Review(id: "R_ann", author: "ann", state: "APPROVED", body: "ok", submittedAt: at(5))],
        threads: [thread("T_cc", [said("C1", "what does @me think?", 4, review: "R_ann")]),
                  thread("T_other", [said("C2", "ask @me-too", 4.5, review: "R_ann")])],
        pendingReview: nil)
    #expect(ids(Conversation.timeline(mentions, viewer: "me", filter: .involvingMe)) == ["IC_cc", "R_cc[]", "R_ann[T_cc]"])
}

@Test func conversationContextIsTheEndOfTheHunk() {
    var hunked = thread("T", [])
    hunked.diffHunk = "@@ -1,3 +1,5 @@\n a\n+b\n+c\n-d\n e\n+f"
    #expect(Conversation.context(hunked).map(\.text) == ["c", "d", "e", "f"])
    #expect(Conversation.context(thread("T", [])).isEmpty)
}
