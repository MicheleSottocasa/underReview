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
              Review(id: "R_bob", author: "bob", state: "APPROVED", body: "ok", submittedAt: at(5))],
    threads: [
        thread("T_bob", [comment("C1", "bob", 4.5, review: "R_bob"), comment("C2", "me", 7)]),
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
            == ["IC_bob", "R_me[T_me,T_me_done]", "R_bob[T_bob]", "IC_me", "T_pending"])
}

@Test func conversationFiltersThreadsTheViewerStarted() {
    // My comments and reviews, my threads; not bob's thread even though I replied in it.
    #expect(ids(Conversation.timeline(detail, viewer: "me", filter: .startedByMe)) == ["R_me[T_me,T_me_done]", "IC_me", "T_pending"])
    #expect(ids(Conversation.timeline(detail, viewer: "bob", filter: .startedByMe)) == ["IC_bob", "R_bob[T_bob]"])
}

@Test func conversationFiltersUnresolvedThreads() {
    #expect(ids(Conversation.timeline(detail, viewer: "me", filter: .unresolved)) == ["R_me[T_me]", "R_bob[T_bob]", "T_pending"])
}

@Test func conversationContextIsTheEndOfTheHunk() {
    var hunked = thread("T", [])
    hunked.diffHunk = "@@ -1,3 +1,5 @@\n a\n+b\n+c\n-d\n e\n+f"
    #expect(Conversation.context(hunked).map(\.text) == ["c", "d", "e", "f"])
    #expect(Conversation.context(thread("T", [])).isEmpty)
}
