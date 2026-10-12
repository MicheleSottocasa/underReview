import ReviewDeskCore
import SwiftUI

/// GitHub-style timeline: the description, then comments and reviews in order.
struct ConversationView: View {
    let pr: PullRequest
    let detail: PRDetail?

    var body: some View {
        if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TimelineCard(author: pr.author, action: "opened this pull request", date: nil,
                                 text: detail.body.isEmpty ? "_No description provided._" : detail.body)
                    ForEach(entries(detail)) { entry in
                        switch entry.kind {
                        case .comment(let comment):
                            TimelineCard(author: comment.author, action: "commented", date: comment.createdAt, text: comment.body)
                        case .review(let review):
                            if review.body.isEmpty {
                                TimelineEvent(review: review)
                            } else {
                                TimelineCard(author: review.author, action: Self.verb(review.state), date: review.submittedAt,
                                             text: review.body, accent: Self.color(review.state))
                            }
                        }
                    }
                    let open = detail.threads.filter { !$0.isResolved }.count
                    if !detail.threads.isEmpty {
                        Label("\(detail.threads.count) inline conversation\(detail.threads.count == 1 ? "" : "s") (\(open) unresolved), shown in Changes",
                              systemImage: "text.bubble")
                            .font(.callout).foregroundStyle(.secondary).padding(.leading, 44)
                    }
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct Entry: Identifiable {
        enum Kind { case comment(Comment), review(Review) }
        var id: String
        var date: Date
        var kind: Kind
    }

    private func entries(_ detail: PRDetail) -> [Entry] {
        (detail.comments.map { Entry(id: $0.id, date: $0.createdAt, kind: .comment($0)) }
            + detail.reviews.map { Entry(id: $0.id, date: $0.submittedAt ?? .distantPast, kind: .review($0)) })
            .sorted { $0.date < $1.date }
    }

    static func verb(_ state: String) -> String {
        switch state {
        case "APPROVED": "approved these changes"
        case "CHANGES_REQUESTED": "requested changes"
        case "DISMISSED": "had a review dismissed"
        default: "reviewed"
        }
    }

    static func color(_ state: String) -> Color {
        switch state {
        case "APPROVED": .green
        case "CHANGES_REQUESTED": .red
        default: .secondary
        }
    }
}

struct TimelineCard: View {
    let author: String
    let action: String
    let date: Date?
    let text: String
    var accent: Color?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(login: author, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(author).bold()
                    Text(action).foregroundStyle(accent ?? .secondary)
                    if let date { Text(date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary) }
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background((accent ?? .secondary).opacity(0.08))
                Divider()
                MarkdownText(text).padding(12)
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke((accent ?? .secondary).opacity(0.35)))
        }
    }
}

/// A review without a body: a compact event line, like GitHub's timeline badges.
struct TimelineEvent: View {
    let review: Review

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: review.state == "APPROVED" ? "checkmark" : review.state == "CHANGES_REQUESTED" ? "exclamationmark" : "eye")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(ConversationView.color(review.state).opacity(review.state == "COMMENTED" ? 0.5 : 1), in: Circle())
            Avatar(login: review.author, size: 20)
            Text(review.author).bold() + Text(" " + ConversationView.verb(review.state)).foregroundStyle(.secondary)
            if let date = review.submittedAt { Text(date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(.leading, 4)
    }
}
