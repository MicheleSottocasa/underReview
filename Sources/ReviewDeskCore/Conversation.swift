import Foundation

/// The Conversation tab's timeline: PR-level comments and reviews in date order, each review with the inline
/// threads it started, like GitHub's.
public enum Conversation {
    public enum Filter: String, CaseIterable, Sendable {
        case all
        /// Threads the viewer started, plus their own PR-level comments and reviews.
        case startedByMe
        case unresolved

        public var title: String {
            switch self {
            case .all: "All"
            case .startedByMe: "Started by Me"
            case .unresolved: "Unresolved"
            }
        }
    }

    public enum Item: Identifiable, Sendable {
        case comment(Comment)
        case review(Review, threads: [ReviewThread])
        /// A thread whose review isn't listed: pending, or older than the reviews fetched.
        case thread(ReviewThread)

        public var id: String {
            switch self {
            case .comment(let comment): comment.id
            case .review(let review, _): review.id
            case .thread(let thread): thread.id
            }
        }

        var date: Date {
            switch self {
            case .comment(let comment): comment.createdAt
            case .review(let review, let threads): review.submittedAt ?? threads.first.map(Conversation.date) ?? .distantPast
            case .thread(let thread): Conversation.date(thread)
            }
        }
    }

    public static func timeline(_ detail: PRDetail, viewer: String, filter: Filter) -> [Item] {
        let threads = detail.threads.filter { thread in
            switch filter {
            case .all: true
            case .startedByMe: thread.comments.first?.author == viewer
            case .unresolved: !thread.isResolved
            }
        }.sorted { date($0) < date($1) }
        let reviewIDs = Set(detail.reviews.map(\.id))
        let byReview = Dictionary(grouping: threads.filter { reviewIDs.contains(reviewID($0)) }, by: reviewID)
        let reviews = detail.reviews.filter { review in
            switch filter {
            case .all: true
            // Each reply is its own empty COMMENTED review: not something the viewer started.
            case .startedByMe: review.author == viewer
                && !(review.state == "COMMENTED" && review.body.isEmpty && byReview[review.id] == nil)
            case .unresolved: byReview[review.id] != nil
            }
        }
        let comments = detail.comments.filter { comment in
            switch filter {
            case .all: true
            case .startedByMe: comment.author == viewer
            case .unresolved: false
            }
        }
        let items = comments.map(Item.comment)
            + reviews.map { Item.review($0, threads: byReview[$0.id] ?? []) }
            + threads.filter { !reviewIDs.contains(reviewID($0)) }.map(Item.thread)
        return items.sorted { $0.date < $1.date }
    }

    /// The last diff lines above a thread's line, from GitHub's hunk for its first comment.
    public static func context(_ thread: ReviewThread, lines: Int = 4) -> [DiffLine] {
        Array(Diff.parse(thread.diffHunk).filter { $0.kind != .hunk }.suffix(lines))
    }

    static func date(_ thread: ReviewThread) -> Date { thread.comments.first?.createdAt ?? .distantPast }

    /// A thread belongs to the review its first comment was posted with.
    static func reviewID(_ thread: ReviewThread) -> String { thread.comments.first?.reviewID ?? "" }
}
