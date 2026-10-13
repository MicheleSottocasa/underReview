import ReviewDeskCore
import SwiftUI

/// GitHub-style timeline: the description, then comments and reviews in order.
struct ConversationView: View {
    let pr: PullRequest
    let detail: PRDetail?
    /// Ids of the folded cards; the description is "description".
    @ViewState private var folded: Set<String> = []

    var body: some View {
        if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let ids = ["description"] + entries(detail).map(\.id)
                    HStack {
                        Spacer()
                        let all = folded.isSuperset(of: ids)
                        Button(all ? "Expand All" : "Collapse All",
                               systemImage: all ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left") {
                            folded = all ? [] : Set(ids)
                        }
                        .controlSize(.small)
                        .help(all ? "Show every comment in full" : "Fold the description and every comment to its header")
                    }
                    TimelineCard(author: pr.author, action: "opened this pull request", date: nil,
                                 text: detail.body.isEmpty ? "_No description provided._" : detail.body,
                                 collapsed: fold("description"))
                    ForEach(entries(detail)) { entry in
                        switch entry.kind {
                        case .comment(let comment):
                            TimelineCard(author: comment.author, action: "commented", date: comment.createdAt, text: comment.body,
                                         comment: comment, pr: pr, collapsed: fold(entry.id))
                        case .review(let review):
                            if review.body.isEmpty {
                                TimelineEvent(review: review)
                            } else {
                                TimelineCard(author: review.author, action: Self.verb(review.state), date: review.submittedAt,
                                             text: review.body, accent: Self.color(review.state), collapsed: fold(entry.id))
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fold(_ id: String) -> Binding<Bool> {
        Binding { folded.contains(id) } set: { if $0 { folded.insert(id) } else { folded.remove(id) } }
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
    /// Set for conversation comments, which can be edited, deleted and reacted to.
    var comment: Comment?
    var pr: PullRequest?
    @Binding var collapsed: Bool
    @ViewState private var editing = false
    @ViewState private var showHidden = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(login: author, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(author).bold()
                    Text(action).foregroundStyle(accent ?? .secondary)
                    if let date { Text(date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary) }
                    Spacer()
                    if let comment, let pr {
                        ExplainButton(pr: pr, comment: comment)
                        CommentMenu(pr: pr, comment: comment, editing: $editing)
                    }
                    Button { collapsed.toggle() } label: {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help(collapsed ? "Expand" : "Collapse")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background((accent ?? .secondary).opacity(0.08))
                if !collapsed { Divider() }
                if collapsed {
                    // Header only.
                } else if let comment, comment.isMinimized, !showHidden {
                    HStack {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                        Text("Marked as resolved").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show") { showHidden = true }.buttonStyle(.link)
                    }
                    .padding(12)
                } else if let comment, let pr {
                    VStack(alignment: .leading, spacing: 8) {
                        EditableCommentBody(pr: pr, comment: comment, editing: $editing)
                        ReactionBar(pr: pr, comment: comment)
                        ExplanationView(comment: comment)
                    }
                    .padding(12)
                } else {
                    MarkdownText(text).padding(12)
                }
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
