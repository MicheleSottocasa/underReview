import ReviewDeskCore
import SwiftUI

/// GitHub-style timeline: the description, then comments and reviews in order, each review with its inline threads.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let detail: PRDetail?
    @AppStorage("conversationFilter") private var filter = Conversation.Filter.all
    /// Ids of the folded cards and threads; the description is "description".
    @ViewState private var folded: Set<String> = []

    var body: some View {
        if let detail {
            let items = Conversation.timeline(detail, viewer: model.viewer, filter: filter)
            let ids = ["description"] + items.map(\.id)
            let hidden: Set<String> = []
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Picker("Show", selection: $filter) {
                            ForEach(Conversation.Filter.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        let all = folded.isSuperset(of: ids)
                        Button(all ? "Expand All" : "Collapse All",
                               systemImage: all ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left") {
                            folded = all ? [] : Set(ids)
                        }
                        .controlSize(.small)
                        .help(all ? "Show every comment in full" : "Fold the description, every comment and every thread to its header")
                    }
                    TimelineCard(author: pr.author, action: "opened this pull request", date: nil,
                                 text: detail.body.isEmpty ? "_No description provided._" : detail.body,
                                 collapsed: fold("description"))
                    ForEach(items) { item in
                        switch item {
                        case .comment(let comment):
                            TimelineCard(author: comment.author, action: "commented", date: comment.createdAt, text: comment.body,
                                         comment: comment, pr: pr, collapsed: fold(item.id))
                        case .review(let review, let threads):
                            let shown = threads.filter { $0.comments.contains { !hidden.contains($0.id) } }
                            if review.body.isEmpty {
                                TimelineEvent(review: review, collapsed: shown.isEmpty ? nil : fold(item.id))
                            } else {
                                TimelineCard(author: review.author, action: Self.verb(review.state), date: review.submittedAt,
                                             text: review.body, accent: Self.color(review.state), collapsed: fold(item.id))
                            }
                            // A folded review folds its threads too.
                            if !folded.contains(item.id) {
                                ForEach(shown) { InlineThread(pr: pr, thread: $0, hidden: hidden) }
                            }
                        case .thread(let thread):
                            if thread.comments.contains(where: { !hidden.contains($0.id) }) {
                                InlineThread(pr: pr, thread: thread, hidden: hidden, collapsed: fold(item.id))
                            }
                        }
                    }
                    if items.isEmpty && filter != .all {
                        Text(filter == .unresolved ? "No unresolved conversations." : "Nothing started by you yet.")
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
        // A card being edited never folds: folding would drop the editor and its unsaved text.
        let folded = collapsed && !editing
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
                        Image(systemName: folded ? "chevron.right" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(editing)
                    .help(folded ? "Expand" : "Collapse")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background((accent ?? .secondary).opacity(0.08))
                if !folded { Divider() }
                if folded {
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

/// An inline review thread in the timeline: its file and line, a link to it in Changes, then the thread.
struct InlineThread: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let thread: ReviewThread
    /// Comments already shown as local drafts.
    let hidden: Set<String>
    /// Set for a thread outside a review, which folds on its own.
    var collapsed: Binding<Bool>?

    var body: some View {
        let folded = collapsed?.wrappedValue == true
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(verbatim: thread.path + (thread.line.map { ":\($0)" } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary)
                Button("Show in Changes") { model.openInChanges(thread.path, line: thread.line, pr: pr) }
                    .buttonStyle(.link).font(.caption)
                if let collapsed {
                    Button { collapsed.wrappedValue.toggle() } label: {
                        Image(systemName: folded ? "chevron.right" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help(folded ? "Expand" : "Collapse")
                }
            }
            .padding(.horizontal, 12)
            if !folded {
                ThreadView(pr: pr, thread: thread, hidden: hidden, foldsOutdated: true, context: Conversation.context(thread))
            }
        }
        .padding(.leading, 44)
    }
}

/// A review without a body: a compact event line, like GitHub's timeline badges.
struct TimelineEvent: View {
    let review: Review
    /// Set when the review has inline threads, which fold under it.
    var collapsed: Binding<Bool>?

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
            if let collapsed {
                Button { collapsed.wrappedValue.toggle() } label: {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(collapsed.wrappedValue ? "Show this review's threads" : "Hide this review's threads")
            }
        }
        .font(.callout)
        .padding(.leading, 4)
    }
}
