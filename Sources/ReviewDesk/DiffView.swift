import ReviewDeskCore
import SwiftUI

struct FilesView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        if let files = model.files[pr.id] {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(files, id: \.filename) { file in
                        FileDiffView(pr: pr, file: file, threads: model.details[pr.id]?.threads.filter { $0.path == file.filename } ?? [])
                    }
                }
                .padding()
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).task { await model.loadFiles(pr) }
        }
    }
}

struct FileDiffView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let file: FileChange
    let threads: [ReviewThread]
    @ViewState private var expanded = true
    @ViewState private var composing: ReviewDeskCore.Anchor?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let patch = file.patch {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Diff.parse(patch).enumerated()), id: \.offset) { _, line in
                        lineRow(line)
                        if let anchor = line.anchor(path: file.filename) { annotations(at: anchor) }
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            } else {
                Text("GitHub doesn't provide a diff for this file (binary or too large).").foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                Text(file.filename).font(.headline.monospaced())
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("−\(file.deletions)").foregroundStyle(.red)
                Text(file.status).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $composing) { anchor in
            DraftEditor(title: "\(anchor.path):\(anchor.line)", initial: "", onCancel: { composing = nil }) { body in
                model.addDraft(pr, anchor: anchor, body: body)
                composing = nil
            }
        }
    }

    private func lineRow(_ line: DiffLine) -> some View {
        let anchor = line.anchor(path: file.filename)
        return HStack(spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.newLine.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            Text(prefix(line.kind) + line.text)
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .background(background(line.kind))
        .contentShape(Rectangle())
        .onTapGesture { if let anchor { composing = anchor } }
        .help(anchor == nil ? "" : "Click to add a draft comment")
    }

    @ViewBuilder
    private func annotations(at anchor: ReviewDeskCore.Anchor) -> some View {
        let lineThreads = anchor.side == .right ? threads.filter { $0.line == anchor.line } : []
        ForEach(lineThreads) { thread in
            VStack(alignment: .leading, spacing: 4) {
                ForEach(thread.comments) { comment in
                    Text(comment.author).font(.caption.bold()) + Text("  ") + Text(comment.body).font(.callout)
                }
                if thread.isResolved { Text("Resolved").font(.caption).foregroundStyle(.secondary) }
            }
            .font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.08))
        }
        ForEach(model.drafts(for: pr.id).filter { $0.anchor == anchor }) { draft in
            DraftCard(draft: draft).padding(6)
        }
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        case .hunk: ""
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.12)
        case .removed: .red.opacity(0.12)
        case .hunk: .blue.opacity(0.08)
        case .context: .clear
        }
    }
}

/// A local draft shown inline, editable in place.
struct DraftCard: View {
    @Environment(AppModel.self) private var model
    let draft: Draft
    @ViewState private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(status, systemImage: draft.isStale ? "exclamationmark.triangle" : "pencil.line").font(.caption.bold())
                Spacer()
                Button("Edit") { editing = true }.buttonStyle(.link)
            }
            MarkdownText(draft.body).font(.callout)
        }
        .padding(8)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .popover(isPresented: $editing) {
            DraftEditor(title: "\(draft.anchor.path):\(draft.anchor.line)", initial: draft.body) { body in
                model.updateDraft(draft.id, body: body)
                editing = false
            }
        }
    }

    private var status: String {
        if draft.isStale { return "Draft · outdated by a new push" }
        if draft.remoteID == nil { return "Draft · local" }
        return draft.needsSync ? "Draft · edited since saved to GitHub" : "Draft · in pending review"
    }
}

/// Markdown editor with preview, shared by drafts, replies and the review body.
struct DraftEditor: View {
    let title: String
    let initial: String
    var actionTitle = "Save Draft"
    var onCancel: (() -> Void)?
    let onSave: (String) -> Void
    @ViewState private var text = ""
    @ViewState private var preview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline.monospaced())
                Spacer()
                Picker("", selection: $preview) {
                    Text("Write").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if preview {
                ScrollView { MarkdownText(text.isEmpty ? "_Nothing to preview._" : text) }.frame(height: 140)
            } else {
                TextEditor(text: $text).font(.body).frame(height: 140)
            }
            HStack {
                Spacer()
                if let onCancel { Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction) }
                Button(actionTitle) { onSave(text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
        .onAppear { text = initial }
    }
}

extension ReviewDeskCore.Anchor: Identifiable {
    public var id: Self { self }
}
