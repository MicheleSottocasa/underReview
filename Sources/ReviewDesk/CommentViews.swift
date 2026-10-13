import ReviewDeskCore
import SwiftUI

struct Avatar: View {
    let login: String
    var size: CGFloat = 22

    var body: some View {
        // GitHub logins never contain dots: the tour's demo people get initials, not someone's photo.
        AsyncImage(url: login.contains(".") ? nil : URL(string: "https://github.com/\(login).png?size=\(Int(size * 2))")) { image in
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
    @ViewState private var resolving = false

    var body: some View {
        let comments = thread.comments.filter { !hidden.contains($0.id) }
        if !comments.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if thread.isResolved && !expanded {
                    HStack {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            let resolver = thread.resolvedBy.map { " by \($0 == model.viewer ? "you" : $0)" } ?? ""
                            Text("Resolved\(resolver) · \(thread.participantList(viewer: model.viewer)) · \(comments.count) comment\(comments.count == 1 ? "" : "s")")
                                .font(.callout)
                            Text(inlineMarkdown(thread.topic))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(comments.first?.body ?? "")
                        }
                        Spacer()
                        resolveButton
                        Button("Show") { expanded = true }.buttonStyle(.link)
                    }
                    .padding(10)
                } else {
                    ForEach(comments) { comment in
                        let mine = comment.author == model.viewer
                        GitHubCommentView(pr: pr, comment: comment, thread: thread) {
                            if mine { Badge(text: "You", color: DiffColors.mine) }
                            if comment.isPending { Badge(text: "Pending") }
                            if thread.isOutdated && comment.id == comments.first?.id { Badge(text: "Outdated", color: .orange) }
                        }
                        .background(mine ? DiffColors.mine.opacity(0.07) : .clear)
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
                            HStack {
                                Button("Reply") { replying = true }.buttonStyle(.link)
                                Spacer()
                                resolveButton
                            }
                            .padding(.leading, 32)
                        }
                    }
                    .padding(10)
                }
            }
            .modifier(ownership)
        }
    }

    /// Started by me: my color. Started by someone else: theirs, tinted when I replied. Dimmed while folded.
    private var ownership: ThreadBox {
        let mine = thread.isStarted(by: model.viewer)
        let color = (mine ? DiffColors.mine : DiffColors.others).opacity(thread.isResolved && !expanded ? 0.45 : 1)
        return ThreadBox(accent: color, bar: color, tint: !mine && thread.hasComment(from: model.viewer) ? color.opacity(0.06) : nil)
    }

    /// GitHub's Resolve / Unresolve conversation, when the viewer is allowed.
    @ViewBuilder
    private var resolveButton: some View {
        if thread.isResolved ? thread.viewerCanUnresolve : thread.viewerCanResolve {
            Button {
                resolving = true
                Task {
                    await model.setResolved(thread, !thread.isResolved, pr: pr)
                    resolving = false
                }
            } label: {
                Label(thread.isResolved ? "Unresolve" : "Resolve conversation",
                      systemImage: thread.isResolved ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(resolving)
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
                    HStack(spacing: 6) {
                        if draft.isStale {
                            Button { model.keepDraftAtHead(draft.id, pr: pr) } label: { Image(systemName: "checkmark.circle") }
                                .help("Still correct at the new head")
                        }
                        Button {
                            text = draft.body
                            editing = true
                        } label: { Image(systemName: "pencil") }
                            .help("Edit draft")
                        Button { Task { await model.deleteDraft(draft, pr: pr) } } label: { Image(systemName: "trash") }
                            .help(draft.remoteID == nil ? "Delete draft" : "Delete draft, also from your pending review on GitHub")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .modifier(ThreadBox(accent: draft.isStale ? DiffColors.outdated : DiffColors.draft))
    }

    @ViewBuilder
    private var status: some View {
        if draft.isStale {
            Badge(text: "Outdated by push", color: DiffColors.outdated)
        } else if draft.remoteID == nil {
            Badge(text: "Draft", color: DiffColors.draft)
        } else if draft.needsSync {
            Badge(text: "Edited", color: DiffColors.draft)
        } else {
            Badge(text: "Pending")
        }
    }
}

struct ThreadBox: ViewModifier {
    var accent: Color?
    /// A bar on the leading edge, and a background tint.
    var bar: Color?
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(.leading, bar == nil ? 0 : 3)
            .background(tint ?? .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if let bar { UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(bar).frame(width: 4) }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent?.opacity(0.6) ?? Color.secondary.opacity(0.3)))
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .frame(maxWidth: 820, alignment: .leading)
    }
}

// MARK: - GitHub comment actions

/// Edit and Delete icons for a comment on GitHub, shown only when GitHub allows them.
struct CommentMenu: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let comment: Comment
    @Binding var editing: Bool
    @ViewState private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 6) {
            if comment.kind == .issue, comment.viewerCanMinimize {
                Button { Task { await model.setHiddenAsResolved(comment, !comment.isMinimized, pr: pr) } } label: {
                    Image(systemName: comment.isMinimized ? "eye" : "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .help(comment.isMinimized ? "Show again (unhide on GitHub)" : "Mark as resolved (hides it on GitHub as Resolved)")
            }
            if comment.viewerCanUpdate {
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .disabled(editing)
                    .help("Edit comment")
            }
            if comment.viewerCanDelete {
                Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete comment")
                    .confirmationDialog("Delete this comment?", isPresented: $confirmingDelete) {
                        Button("Delete", role: .destructive) { Task { await model.deleteComment(comment, pr: pr) } }
                    } message: {
                        Text("It is deleted on GitHub for everyone. This can't be undone.")
                    }
            }
        }
        .foregroundStyle(.secondary)
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
    @ViewState private var picking = false

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
                    Button { picking = true } label: { Image(systemName: "face.smiling") }
                        .buttonStyle(.borderless)
                        .help("Add reaction")
                        .popover(isPresented: $picking, arrowEdge: .bottom) {
                            ReactionPicker(given: Set(comment.reactions.filter(\.viewerHasReacted).map(\.content))) { content in
                                picking = false
                                if let content { toggle(content) }
                            }
                        }
                }
            }
        }
    }

    private func toggle(_ content: ReactionContent) {
        Task { await model.toggleReaction(content, on: comment, pr: pr) }
    }
}

/// GitHub's reaction picker: the 8 emoji in one row. Arrow keys move, Return picks, Esc closes (`done(nil)`).
private struct ReactionPicker: View {
    let given: Set<ReactionContent>
    let done: (ReactionContent?) -> Void
    @ViewState private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        let all = ReactionContent.allCases
        HStack(spacing: 2) {
            ForEach(Array(all.enumerated()), id: \.element) { index, content in
                let mine = given.contains(content)
                Button { done(content) } label: {
                    Text(content.emoji)
                        .font(.title3)
                        .frame(width: 32, height: 30)
                        .background(mine ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                            index == selected ? Color.primary.opacity(0.5) : mine ? Color.accentColor.opacity(0.7) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(content.name)
                .onHover { if $0 { selected = index } }
            }
        }
        .padding(6)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.rightArrow) { selected = min(selected + 1, all.count - 1); return .handled }
        .onKeyPress(.return) { done(all[selected]); return .handled }
        .onKeyPress(.escape) { done(nil); return .handled }
    }
}

/// A comment from GitHub inside a diff thread: menu, editable text and reactions.
struct GitHubCommentView<Badges: View>: View {
    let pr: PullRequest
    let comment: Comment
    let thread: ReviewThread
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
                    ExplainButton(pr: pr, comment: comment, thread: thread)
                    CommentMenu(pr: pr, comment: comment, editing: $editing)
                }
                EditableCommentBody(pr: pr, comment: comment, editing: $editing).font(.callout)
                ReactionBar(pr: pr, comment: comment).padding(.top, 2)
                ExplanationView(comment: comment).padding(.top, 4)
            }
        }
        .padding(10)
    }
}

// MARK: - AI explanation

/// ✨ Explain (the AI answers first) and 💬 Ask (the reviewer asks first), both opening the comment's chat.
struct ExplainButton: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let comment: Comment
    var thread: ReviewThread?

    var body: some View {
        let engine = model.preferredEngine(for: pr)
        let sends = engine.isLocal ? "" : " Sends the comment, its conversation and the file's diff to \(engine.name)'s provider."
        let busy = model.explanations[comment.id]?.isAnswering == true
        HStack(spacing: 6) {
            Button { model.explain(comment, thread: thread, pr: pr) } label: { Image(systemName: "sparkles") }
                .disabled(busy)
                .help("Explain this comment with \(engine.name), then ask follow-ups.\(sends)")
            Button { model.openChat(comment, thread: thread, pr: pr) } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
                .disabled(model.explanations[comment.id] != nil)
                .help("Ask \(engine.name) your own question about this comment.\(sends)")
        }
        .buttonStyle(.borderless)
    }
}

/// The Explain chat under the comment: the answer, then follow-up questions with the same context.
struct ExplanationView: View {
    @Environment(AppModel.self) private var model
    let comment: Comment
    @ViewState private var question = ""

    var body: some View {
        if let chat = model.explanations[comment.id] {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                    Text(chat.isAnswering && chat.messages.isEmpty ? "Asking \(chat.engine.name)…" : "Chat about this comment · \(chat.engine.name)")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    if chat.isAnswering { ProgressView().controlSize(.small) }
                    Spacer()
                    if !chat.isAnswering {
                        Button { model.explanations[comment.id] = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Close the chat")
                    }
                }
                ForEach(Array(chat.messages.enumerated()), id: \.offset) { _, message in
                    if message.role == .reviewer {
                        HStack {
                            Spacer(minLength: 40)
                            Text(message.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                        }
                    } else {
                        MarkdownText(message.text).font(.callout)
                    }
                }
                // Once the context is ready: after the explanation, or straight away for a direct chat.
                if !chat.prompt.isEmpty && !(chat.isAnswering && chat.messages.isEmpty) {
                    HStack {
                        TextField(chat.messages.isEmpty ? "Ask about this comment…" : "Ask a follow-up…", text: $question)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(send)
                            .disabled(chat.isAnswering)
                        Button("Ask", action: send)
                            .disabled(chat.isAnswering || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .help("Same context as the explanation: PR description, conversation and diff")
                }
            }
            .padding(10)
            .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.purple.opacity(0.3)))
        }
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { if await model.askFollowUp(text, about: comment.id) { question = "" } }
    }
}
