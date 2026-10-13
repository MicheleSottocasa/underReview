import ReviewDeskCore
import SwiftUI

struct Avatar: View {
    let login: String
    var size: CGFloat = 22

    var body: some View {
        AsyncImage(url: URL(string: "https://github.com/\(login).png?size=\(Int(size * 2))")) { image in
            image.resizable()
        } placeholder: {
            Circle().fill(.quaternary).overlay(Text(login.prefix(1).uppercased()).font(.caption2.bold()))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        // PyCharm-style tag: uppercase text on a filled, slightly rounded rectangle.
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// "Today at 3:16 PM", like PyCharm's review comments. File-level because generic types can't hold stored statics.
private let commentDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.doesRelativeDateFormatting = true
    return formatter
}()

/// One comment: avatar, author, time, badges and Markdown text.
struct CommentView<Badges: View, Actions: View>: View {
    let author: String
    let date: Date?
    let text: String
    @ViewBuilder var badges: Badges
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(login: author)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(author).font(.callout.bold())
                    if let date { Text(commentDateFormatter.string(from: date)).font(.caption).foregroundStyle(.secondary) }
                    badges
                    Spacer()
                    actions
                }
                MarkdownText(text).font(.callout)
            }
        }
        .padding(10)
    }
}

extension CommentView where Actions == EmptyView {
    init(author: String, date: Date?, text: String, @ViewBuilder badges: () -> Badges) {
        self.init(author: author, date: date, text: text, badges: badges, actions: { EmptyView() })
    }
}

/// Markdown editor with Write/Preview tabs, used for drafts, replies and the review summary.
struct CommentComposer: View {
    @Binding var text: String
    var placeholder = "Leave a comment"
    var submitTitle = "Add Comment"
    var onCancel: (() -> Void)?
    var onSubmit: (() -> Void)?
    @ViewState private var preview = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $preview) {
                Text("Write").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Group {
                if preview {
                    ScrollView { MarkdownText(text.isEmpty ? "_Nothing to preview_" : text).font(.callout).padding(6) }
                } else {
                    TextEditor(text: $text)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty { Text(placeholder).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false) }
                        }
                }
            }
            .frame(minHeight: 70, maxHeight: 180)
            .padding(4)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor : Color.secondary.opacity(0.3)))
            if onSubmit != nil || onCancel != nil {
                HStack {
                    Text("Markdown supported").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if let onCancel { Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction) }
                    if let onSubmit {
                        Button(submitTitle, action: onSubmit)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .onAppear { focused = true }
    }
}

/// A GitHub review thread inline in the diff, PyCharm style, with an inline reply box.
struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let thread: ReviewThread
    /// Comments already shown as local drafts.
    let hidden: Set<String>
    @ViewState private var expanded = false
    @ViewState private var replying = false
    @ViewState private var reply = ""
    @ViewState private var sending = false

    var body: some View {
        let comments = thread.comments.filter { !hidden.contains($0.id) }
        if !comments.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if thread.isResolved && !expanded {
                    HStack {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                        Text("Resolved conversation · \(comments.count) comment\(comments.count == 1 ? "" : "s")").font(.callout)
                        Spacer()
                        Button("Show") { expanded = true }.buttonStyle(.link)
                    }
                    .padding(10)
                } else {
                    ForEach(comments) { comment in
                        GitHubCommentView(pr: pr, comment: comment) {
                            if comment.isPending { Badge(text: "Pending") }
                            if thread.isOutdated && comment.id == comments.first?.id { Badge(text: "Outdated", color: .orange) }
                        }
                        Divider().padding(.leading, 42)
                    }
                    Group {
                        if replying {
                            CommentComposer(text: $reply, placeholder: "Reply…", submitTitle: sending ? "Sending…" : "Reply",
                                            onCancel: { replying = false; reply = "" }) {
                                sending = true
                                Task {
                                    if await model.reply(to: thread.id, body: reply, pr: pr) {
                                        replying = false
                                        reply = ""
                                    }
                                    sending = false
                                }
                            }
                            .disabled(sending)
                        } else {
                            Button("Reply") { replying = true }
                                .buttonStyle(.link)
                                .padding(.leading, 32)
                        }
                    }
                    .padding(10)
                }
            }
            .modifier(ThreadBox())
        }
    }
}

/// A local draft inline in the diff: edit, delete, or confirm after a push.
struct DraftView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let draft: Draft
    @ViewState private var editing = false
    @ViewState private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editing {
                CommentComposer(text: $text, submitTitle: "Update", onCancel: { editing = false }) {
                    model.updateDraft(draft.id, body: text)
                    editing = false
                }
                .padding(10)
            } else {
                CommentView(author: model.viewer, date: nil, text: draft.body) {
                    status
                } actions: {
                    Menu {
                        Button("Edit") {
                            text = draft.body
                            editing = true
                        }
                        if draft.isStale { Button("Still Correct at New Head") { model.keepDraftAtHead(draft.id, pr: pr) } }
                        Divider()
                        Button("Delete", role: .destructive) { Task { await model.deleteDraft(draft, pr: pr) } }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                }
            }
        }
        .modifier(ThreadBox(accent: draft.isStale ? .orange : .accentColor))
    }

    @ViewBuilder
    private var status: some View {
        if draft.isStale {
            Badge(text: "Outdated by push", color: .orange)
        } else if draft.remoteID == nil {
            Badge(text: "Draft", color: .accentColor)
        } else if draft.needsSync {
            Badge(text: "Edited", color: .accentColor)
        } else {
            Badge(text: "Pending")
        }
    }
}

struct ThreadBox: ViewModifier {
    var accent: Color?

    func body(content: Content) -> some View {
        content
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent?.opacity(0.6) ?? Color.secondary.opacity(0.3)))
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .frame(maxWidth: 820, alignment: .leading)
    }
}

// MARK: - GitHub comment actions

/// Edit and Delete for a comment on GitHub, shown only when GitHub allows them.
struct CommentMenu: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let comment: Comment
    @Binding var editing: Bool
    @ViewState private var confirmingDelete = false

    var body: some View {
        if comment.viewerCanUpdate || comment.viewerCanDelete {
            Menu {
                if comment.viewerCanUpdate { Button("Edit") { editing = true } }
                if comment.viewerCanDelete { Button("Delete…", role: .destructive) { confirmingDelete = true } }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .confirmationDialog("Delete this comment?", isPresented: $confirmingDelete) {
                    Button("Delete", role: .destructive) { Task { await model.deleteComment(comment, pr: pr) } }
                } message: {
                    Text("It is deleted on GitHub for everyone. This can't be undone.")
                }
        }
    }
}

/// The comment text, or an editor in its place while editing.
struct EditableCommentBody: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let comment: Comment
    @Binding var editing: Bool
    @ViewState private var text = ""
    @ViewState private var saving = false

    var body: some View {
        if editing {
            CommentComposer(text: $text, submitTitle: saving ? "Saving…" : "Update", onCancel: { editing = false }) {
                saving = true
                Task {
                    if await model.editComment(comment, body: text, pr: pr) { editing = false }
                    saving = false
                }
            }
            .disabled(saving)
            .onAppear { text = comment.body }
        } else {
            MarkdownText(comment.body)
        }
    }
}

/// GitHub's reaction pills, plus a picker to add one. Clicking a pill you gave removes it.
struct ReactionBar: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let comment: Comment

    var body: some View {
        if comment.viewerCanReact || !comment.reactions.isEmpty {
            HStack(spacing: 4) {
                ForEach(comment.reactions, id: \.content) { reaction in
                    Button { toggle(reaction.content) } label: {
                        Text("\(reaction.content.emoji) \(reaction.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(reaction.viewerHasReacted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08), in: Capsule())
                            .overlay(Capsule().stroke(reaction.viewerHasReacted ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!comment.viewerCanReact)
                    .help(reaction.viewerHasReacted ? "Remove your reaction" : "React")
                }
                if comment.viewerCanReact {
                    Menu {
                        ForEach(ReactionContent.allCases, id: \.self) { content in
                            Button(content.emoji) { toggle(content) }
                        }
                    } label: { Image(systemName: "face.smiling") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add reaction")
                }
            }
        }
    }

    private func toggle(_ content: ReactionContent) {
        Task { await model.toggleReaction(content, on: comment, pr: pr) }
    }
}

/// A comment from GitHub inside a diff thread: menu, editable text and reactions.
struct GitHubCommentView<Badges: View>: View {
    let pr: PullRequest
    let comment: Comment
    @ViewBuilder var badges: Badges
    @ViewState private var editing = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(login: comment.author)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author).font(.callout.bold())
                    Text(commentDateFormatter.string(from: comment.createdAt)).font(.caption).foregroundStyle(.secondary)
                    badges
                    Spacer()
                    CommentMenu(pr: pr, comment: comment, editing: $editing)
                }
                EditableCommentBody(pr: pr, comment: comment, editing: $editing).font(.callout)
                ReactionBar(pr: pr, comment: comment).padding(.top, 2)
            }
        }
        .padding(10)
    }
}
