import ReviewDeskCore
import SwiftUI

enum DiffMode: String {
    case split, unified
}

/// PyCharm-style review: file tree, diff with inline threads and drafts, and a review bar.
struct ChangesView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    @AppStorage("diffMode") private var mode = DiffMode.split
    @ViewState private var selectedPath: String?

    var body: some View {
        VStack(spacing: 0) {
            ReviewBar(pr: pr, mode: $mode)
            Divider()
            if let files = model.files[pr.id] {
                HSplitView {
                    FileTree(pr: pr, files: files, selection: $selectedPath)
                        .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)
                    Group {
                        if let file = files.first(where: { $0.filename == selectedPath }) ?? files.first {
                            FileDiffView(pr: pr, file: file, mode: mode).id(file.filename)
                        } else {
                            ContentUnavailableView("No changed files", systemImage: "doc")
                        }
                    }
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if model.files[pr.id] == nil { await model.loadFiles(pr) } }
    }
}

// MARK: - Review bar

struct ReviewBar: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    @Binding var mode: DiffMode
    @ViewState private var finishing = false
    @ViewState private var saving = false

    var body: some View {
        let drafts = model.drafts(for: pr.id)
        let unsaved = drafts.filter { $0.needsSync && !$0.isStale }
        let stale = drafts.filter(\.isStale).count
        let pending = model.details[pr.id]?.pendingReview?.comments.count ?? 0
        HStack(spacing: 12) {
            Picker("", selection: $mode) {
                Image(systemName: "rectangle.split.2x1").help("Side by side").tag(DiffMode.split)
                Image(systemName: "rectangle").help("Unified").tag(DiffMode.unified)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if stale > 0 {
                Label("\(stale) outdated", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            Text(summary(pending: pending, unsaved: unsaved.count)).font(.callout).foregroundStyle(.secondary)
            Button(saving ? "Saving…" : "Save Drafts to GitHub") {
                saving = true
                Task {
                    await model.saveDrafts(Set(unsaved.map(\.id)), pr: pr)
                    saving = false
                }
            }
            .disabled(unsaved.isEmpty || saving)
            .help("Adds local drafts to your pending review on GitHub (visible only to you)")
            Button("Finish Review") { finishing = true }
                .buttonStyle(.borderedProminent)
                .popover(isPresented: $finishing, arrowEdge: .bottom) { SubmitReviewPopover(pr: pr) { finishing = false } }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func summary(pending: Int, unsaved: Int) -> String {
        var parts: [String] = []
        if pending > 0 { parts.append("\(pending) pending on GitHub") }
        if unsaved > 0 { parts.append("\(unsaved) local") }
        return parts.isEmpty ? "No review comments yet" : parts.joined(separator: " · ")
    }
}

/// GitHub's "Review changes" box: summary, an explicit action, submit.
struct SubmitReviewPopover: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let close: () -> Void
    @ViewState private var event: ReviewEvent?
    @ViewState private var submitting = false

    var body: some View {
        let unsaved = model.drafts(for: pr.id).filter(\.needsSync)
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish your review").font(.headline)
            CommentComposer(text: Binding(
                get: { model.reviewDrafts.bodies[pr.id] ?? "" },
                set: { model.reviewDrafts.bodies[pr.id] = $0.isEmpty ? nil : $0 }
            ), placeholder: "Leave a summary (optional)")
            Picker("", selection: $event) {
                option(.comment, "Comment", "Submit general feedback without explicit approval.")
                option(.approve, "Approve", "Submit feedback and approve merging these changes.")
                option(.requestChanges, "Request changes", "Submit feedback that must be addressed before merging.")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if unsaved.contains(where: \.isStale) {
                Label("Outdated drafts are left out until you confirm or delete them.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if !unsaved.isEmpty {
                Text("\(unsaved.count) local draft(s) will be added to the review.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(submitting ? "Submitting…" : "Submit Review") {
                    guard let event else { return }
                    submitting = true
                    Task {
                        if await model.submitReview(pr, event: event) { close() }
                        submitting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(event == nil || submitting)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func option(_ value: ReviewEvent, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).bold()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .tag(ReviewEvent?.some(value))
    }
}

// MARK: - File tree

struct FileNode: Identifiable {
    var id: String
    var name: String
    var file: FileChange?
    var children: [FileNode]?

    /// Directory tree with single-child directories collapsed ("a/b/c"), like PyCharm.
    static func tree(_ files: [FileChange]) -> [FileNode] {
        build(files.map { ($0.filename.split(separator: "/").map(String.init), $0) }, prefix: "")
    }

    private static func build(_ entries: [([String], FileChange)], prefix: String) -> [FileNode] {
        let groups = Dictionary(grouping: entries) { $0.0.count == 1 ? "" : $0.0[0] }
        var nodes: [FileNode] = []
        for (dir, members) in groups.sorted(by: { $0.key < $1.key }) where !dir.isEmpty {
            var name = dir
            var rest = members.map { (Array($0.0.dropFirst()), $0.1) }
            while rest.allSatisfy({ $0.0.count > 1 }), Set(rest.map { $0.0[0] }).count == 1, let next = rest.first?.0.first {
                name += "/" + next
                rest = rest.map { (Array($0.0.dropFirst()), $0.1) }
            }
            nodes.append(FileNode(id: prefix + name + "/", name: name, children: build(rest, prefix: prefix + name + "/")))
        }
        nodes += (groups[""] ?? []).sorted { $0.1.filename < $1.1.filename }.map {
            FileNode(id: $0.1.filename, name: $0.0[0], file: $0.1)
        }
        return nodes
    }
}

struct FileTree: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let files: [FileChange]
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(FileNode.tree(files)) { FileTreeNode(pr: pr, node: $0) }
        }
        .listStyle(.sidebar)
        .onAppear { if selection == nil { selection = files.first?.filename } }
    }
}

struct FileTreeNode: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let node: FileNode
    @ViewState private var expanded = true

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children) { FileTreeNode(pr: pr, node: $0) }
            } label: {
                Label(node.name, systemImage: "folder").lineLimit(1).truncationMode(.head)
            }
        } else if let file = node.file {
            HStack(spacing: 6) {
                Image(systemName: icon(file.status)).foregroundStyle(color(file.status)).frame(width: 14)
                Text(node.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                let comments = commentCount(file.filename)
                if comments > 0 {
                    Label("\(comments)", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
            }
            .help("\(file.filename)  +\(file.additions) −\(file.deletions)")
            .tag(file.filename)
        }
    }

    private func commentCount(_ path: String) -> Int {
        let threads = model.details[pr.id]?.threads.filter { $0.path == path }.reduce(0) { $0 + $1.comments.count } ?? 0
        return threads + model.drafts(for: pr.id).filter { $0.anchor.path == path && $0.remoteID == nil }.count
    }

    private func icon(_ status: String) -> String {
        switch status {
        case "added": "plus.square"
        case "removed": "minus.square"
        case "renamed": "arrow.right.square"
        default: "pencil.line"
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "added": .green
        case "removed": .red
        case "renamed": .purple
        default: .blue
        }
    }
}

// MARK: - Diff

struct FileDiffView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let file: FileChange
    let mode: DiffMode
    @ViewState private var hovered: ReviewDeskCore.Anchor?
    @ViewState private var composing: ReviewDeskCore.Anchor?
    @ViewState private var draftText = ""

    var body: some View {
        let threads = model.details[pr.id]?.threads.filter { $0.path == file.filename } ?? []
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(file.filename).font(.callout.monospaced()).textSelection(.enabled)
                Text("+\(file.additions)").foregroundStyle(.green).font(.callout.monospacedDigit())
                Text("−\(file.deletions)").foregroundStyle(.red).font(.callout.monospacedDigit())
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            if let patch = file.patch {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let detached = threads.filter { $0.line == nil }
                        if !detached.isEmpty {
                            Text("Comments on lines no longer in the diff").font(.caption).foregroundStyle(.secondary).padding([.top, .leading], 12)
                            ForEach(detached) { ThreadView(pr: pr, thread: $0, hidden: hiddenIDs) }
                        }
                        let lines = Diff.parse(patch)
                        switch mode {
                        case .unified:
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                unifiedRow(line)
                                if let anchor = line.anchor(path: file.filename) { annotations(anchor, threads: threads) }
                            }
                        case .split:
                            ForEach(Array(Diff.sideBySide(lines).enumerated()), id: \.offset) { _, row in
                                splitRow(row)
                                ForEach(anchors(row), id: \.self) { annotations($0, threads: threads) }
                            }
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            } else {
                ContentUnavailableView("No diff available", systemImage: "doc.questionmark",
                                       description: Text("GitHub doesn't provide a diff for binary or very large files."))
            }
        }
    }

    private var hiddenIDs: Set<String> { Set(model.drafts(for: pr.id).compactMap(\.remoteID)) }

    // MARK: Rows

    private func unifiedRow(_ line: DiffLine) -> some View {
        let anchor = line.anchor(path: file.filename)
        return HStack(spacing: 0) {
            if line.kind == .hunk {
                hunk(line.text)
            } else {
                gutter(line.oldLine, anchor: line.kind == .removed ? anchor : nil)
                gutter(line.newLine, anchor: line.kind == .removed ? nil : anchor)
                code(line)
            }
        }
        .background(background(line.kind))
        .onHover { track(anchor, $0) }
    }

    private func splitRow(_ row: DiffRow) -> some View {
        HStack(spacing: 0) {
            if let text = row.hunk {
                hunk(text)
            } else {
                half(row.left, left: true)
                Divider()
                half(row.right, left: false)
            }
        }
    }

    private func half(_ line: DiffLine?, left: Bool) -> some View {
        let anchor = side(line, left: left)
        return HStack(spacing: 0) {
            if let line {
                gutter(left ? line.oldLine : line.newLine, anchor: anchor)
                code(line)
            } else {
                Color.secondary.opacity(0.06)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(line.map { background($0.kind) } ?? .clear)
        .onHover { track(anchor, $0) }
    }

    /// Left half comments only on removed lines; context and added lines take comments on the right.
    private func side(_ line: DiffLine?, left: Bool) -> ReviewDeskCore.Anchor? {
        guard let line else { return nil }
        if left { return line.kind == .removed ? line.anchor(path: file.filename) : nil }
        return line.kind == .removed ? nil : line.anchor(path: file.filename)
    }

    private func anchors(_ row: DiffRow) -> [ReviewDeskCore.Anchor] {
        [side(row.left, left: true), side(row.right, left: false)].compactMap { $0 }
    }

    private func gutter(_ number: Int?, anchor: ReviewDeskCore.Anchor?) -> some View {
        ZStack(alignment: .leading) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            if let anchor, hovered == anchor {
                Button {
                    draftText = ""
                    composing = anchor
                } label: {
                    Image(systemName: "plus.square.fill").symbolRenderingMode(.multicolor).foregroundStyle(.white, Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Add a review comment")
            }
        }
        .frame(width: 48)
    }

    private func code(_ line: DiffLine) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .padding(.leading, 6)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func hunk(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.vertical, 3)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.13)
        case .removed: .red.opacity(0.13)
        case .hunk, .context: .clear
        }
    }

    private func track(_ anchor: ReviewDeskCore.Anchor?, _ inside: Bool) {
        if inside { hovered = anchor } else if hovered == anchor { hovered = nil }
    }

    // MARK: Inline comments

    @ViewBuilder
    private func annotations(_ anchor: ReviewDeskCore.Anchor, threads: [ReviewThread]) -> some View {
        ForEach(threads.filter { $0.line == anchor.line && $0.side == anchor.side }) {
            ThreadView(pr: pr, thread: $0, hidden: hiddenIDs).font(.body)
        }
        ForEach(model.drafts(for: pr.id).filter { $0.anchor == anchor }) {
            DraftView(pr: pr, draft: $0).font(.body)
        }
        if composing == anchor {
            CommentComposer(text: $draftText, placeholder: "Add a review comment", submitTitle: "Add to Review",
                            onCancel: { composing = nil }) {
                model.addDraft(pr, anchor: anchor, body: draftText)
                composing = nil
            }
            .font(.body)
            .padding(10)
            .modifier(ThreadBox(accent: .accentColor))
        }
    }
}
