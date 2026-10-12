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
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .overlay(Capsule().stroke(color.opacity(0.6)))
    }
}

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
                    if let date { Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary) }
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
                        CommentView(author: comment.author, date: comment.createdAt, text: comment.body) {
                            if comment.isPending { Badge(text: "Pending", color: .orange) }
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
                            Button { replying = true } label: {
                                Text("Reply…").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                            }
                            .buttonStyle(.plain)
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
            Badge(text: "Pending", color: .orange)
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
