import ReviewDeskCore
import SwiftUI

struct ReviewView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    @ViewState private var selection: Set<UUID> = []
    @ViewState private var event: ReviewEvent?
    @ViewState private var working = false
    @ViewState private var confirming = false
    @ViewState private var replyingTo: ReviewThread?

    var body: some View {
        let drafts = model.drafts(for: pr.id)
        let detail = model.details[pr.id]
        Form {
            Section("Drafts") {
                if drafts.isEmpty {
                    Text("No drafts. Click a line in Files to write one.").foregroundStyle(.secondary)
                }
                ForEach(drafts) { draft in
                    HStack(alignment: .top) {
                        Toggle("", isOn: selectionBinding(draft.id)).labelsHidden().disabled(draft.isStale)
                        VStack(alignment: .leading) {
                            Text("\(draft.anchor.path):\(draft.anchor.line)").font(.caption.monospaced())
                            DraftCard(draft: draft)
                        }
                        Menu {
                            if draft.isStale { Button("Still Correct at New Head") { model.keepDraftAtHead(draft.id, pr: pr) } }
                            Button("Delete", role: .destructive) { run { await model.deleteDraft(draft, pr: pr) } }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                    }
                }
                if !drafts.isEmpty {
                    Button("Save \(selection.count) Selected to GitHub as Pending") {
                        let ids = selection
                        run { await model.saveDrafts(ids, pr: pr) }
                    }
                    .disabled(selection.isEmpty || working)
                }
            }

            let outside = (detail?.pendingReview?.comments ?? []).filter { comment in !drafts.contains { $0.remoteID == comment.id } }
            if !outside.isEmpty {
                Section("Also in your pending review (added on github.com)") {
                    ForEach(outside) { comment in
                        VStack(alignment: .leading) {
                            Text("\(comment.path):\(comment.line.map(String.init) ?? "–")").font(.caption.monospaced())
                            MarkdownText(comment.body)
                        }
                    }
                }
            }

            Section("Publish") {
                Picker("Action", selection: $event) {
                    Text("Choose…").tag(ReviewEvent?.none)
                    Text("Comment").tag(ReviewEvent?.some(.comment))
                    Text("Approve").tag(ReviewEvent?.some(.approve))
                    Text("Request Changes").tag(ReviewEvent?.some(.requestChanges))
                }
                TextEditor(text: Binding(
                    get: { model.reviewDrafts.bodies[pr.id] ?? "" },
                    set: { model.reviewDrafts.bodies[pr.id] = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 80)
                if let body = model.reviewDrafts.bodies[pr.id] {
                    LabeledContent("Preview") { MarkdownText(body) }
                }
                let unsaved = drafts.filter(\.needsSync).count
                if unsaved > 0 {
                    Label("\(unsaved) draft(s) not saved to GitHub won't be included.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button("Publish Review…") { confirming = true }
                    .disabled(event == nil || working)
            }

            if let threads = detail?.threads, !threads.isEmpty {
                Section("Conversations") {
                    ForEach(threads) { thread in ThreadRow(thread: thread) { replyingTo = thread } }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(working)
        .overlay { if working { ProgressView() } }
        .onAppear { selection = Set(drafts.filter { $0.needsSync && !$0.isStale }.map(\.id)) }
        .confirmationDialog(publishTitle, isPresented: $confirming) {
            Button(publishTitle) {
                guard let event else { return }
                run { if await model.publish(pr, event: event) { self.event = nil } }
            }
        } message: {
            Text("This submits your pending review on \(pr.repo)#\(pr.number). It can't be undone from ReviewDesk.")
        }
        .sheet(item: $replyingTo) { thread in
            DraftEditor(title: "Reply · \(thread.path)", initial: "", actionTitle: "Send Reply", onCancel: { replyingTo = nil }) { body in
                run { if await model.reply(to: thread.id, body: body, pr: pr) { replyingTo = nil } }
            }
        }
    }

    private var publishTitle: String {
        switch event {
        case .approve: "Approve"
        case .requestChanges: "Request Changes"
        default: "Comment"
        }
    }

    private func selectionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { selection.contains(id) }, set: { if $0 { selection.insert(id) } else { selection.remove(id) } })
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        working = true
        Task {
            await action()
            working = false
        }
    }
}

struct ThreadRow: View {
    let thread: ReviewThread
    let onReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(thread.path):\(thread.line.map(String.init) ?? "outdated")").font(.caption.monospaced())
                if thread.isResolved { Text("Resolved").font(.caption).foregroundStyle(.secondary) }
                if thread.isOutdated { Text("Outdated").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Reply…", action: onReply)
            }
            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 2) {
                    Text(comment.author).font(.caption.bold())
                    MarkdownText(comment.body)
                }
            }
        }
    }
}
