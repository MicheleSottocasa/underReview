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
    @ViewState private var target: LineTarget?

    var body: some View {
        VStack(spacing: 0) {
            ReviewBar(pr: pr, mode: $mode)
            Divider()
            let analysis = model.keyAreasRun(for: pr)
            if let analysis, analysis.isOutdated(for: pr) {
                OutdatedAnalysisBanner(pr: pr, run: analysis).padding(8)
                Divider()
            }
            if let files = model.files[pr.id] {
                HSplitView {
                    FileTree(pr: pr, files: files, selection: $selectedPath) { path, line in
                        selectedPath = path
                        target = line.map { LineTarget(path: path, line: $0) }
                    }
                        .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)
                    Group {
                        if let file = files.first(where: { $0.filename == selectedPath }) ?? files.first {
                            // An added or deleted file has one empty side: show it full width.
                            FileDiffView(pr: pr, file: file, mode: ["added", "removed"].contains(file.status) ? .unified : mode, target: target?.path == file.filename ? target : nil,
                                         keyAreas: analysis?.result.keyAreas.filter { $0.path == file.filename } ?? [],
                                         keyAreasOutdated: analysis?.isOutdated(for: pr) == true)
                                .id(file.filename)
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
        .onChange(of: model.changesTarget?.id, initial: true) {
            // Sent here from another tab (e.g. Risk): open the file and, when there's a line, scroll to it.
            guard let next = model.changesTarget else { return }
            selectedPath = next.path
            target = next.line > 0 ? next : nil
            model.changesTarget = nil
        }
    }
}

/// A line to scroll to; a fresh id lets the same section be revisited.
struct LineTarget: Equatable {
    var path: String
    var line: Int
    /// Left: `line` is in the old file, as for comments on removed lines.
    var side = DiffSide.right
    var id = UUID()
}

// MARK: - Review bar

struct ReviewBar: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    @Binding var mode: DiffMode
    @AppStorage("wrapLines") private var wrap = false
    @AppStorage("involvedFilter") private var involvedOnly = false
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
            Toggle(isOn: $wrap) { Image(systemName: "arrow.turn.down.left") }
                .toggleStyle(.button)
                .help("Soft-wrap long lines")
            Toggle(isOn: $involvedOnly) { Label("Involving Me", systemImage: "person.crop.circle") }
                .toggleStyle(.button)
                .help("Show only the review threads you started, replied in or are @mentioned in, and, when there are some, only the files that have one")
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

/// Flat rows with depth indentation and our own chevrons: DisclosureGroup rows in this List drew some
/// labels twice, and PyCharm's tree behaves like this anyway.
struct FileTree: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let files: [FileChange]
    @Binding var selection: String?
    /// A key area was clicked: open the file and, when it has lines, scroll there.
    let openArea: (String, Int?) -> Void
    @ViewState private var collapsed: Set<String> = []
    @AppStorage("focusFilter") private var focusOnly = false
    @AppStorage("involvedFilter") private var involvedOnly = false

    var body: some View {
        let focus = model.focus(for: pr)
        let involved = involvedThreads
        VStack(spacing: 0) {
            Picker("", selection: $focusOnly) {
                Text("All").tag(false)
                Text("Focus (\(focus.count))").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            .help("Focus: the key files and sections from the latest AI review, plus every file with comments you haven't submitted")
            List(selection: $selection) {
                if focusOnly {
                    focusRows(focus)
                } else {
                    if involvedOnly && involved.isEmpty {
                        Text("No review threads involve you, so all files are listed.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(rows(FileNode.tree(involvedOnly && !involved.isEmpty ? files.filter { involved[$0.filename] != nil } : files), depth: 0), id: \.node.id) { row in
                        if let file = row.node.file {
                            fileRow(file, name: row.node.name, involved: involved[file.filename])
                                .padding(.leading, CGFloat(row.depth) * 14 + 16)
                                .tag(file.filename)
                        } else {
                            folderRow(row.node)
                                .padding(.leading, CGFloat(row.depth) * 14)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .onAppear { if selection == nil { selection = files.first?.filename } }
    }

    @ViewBuilder
    private func focusRows(_ focus: [FocusFile]) -> some View {
        if focus.isEmpty {
            Text("Run an AI review to list the key files to read. Files with comments you haven't submitted show here too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(focus, id: \.path) { item in
            if let file = files.first(where: { $0.filename == item.path }) {
                fileRow(file, name: item.path).tag(file.filename)
                ForEach(Array(item.areas.enumerated()), id: \.offset) { _, area in
                    Button { openArea(item.path, area.startLine) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.lines(area) + (area.question.map { " · \($0.label)" } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(inlineMarkdown(area.reason)).font(.caption).lineLimit(3).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 22)
                    .help(area.startLine == nil ? "Open the file" : "Jump to these lines")
                }
            }
        }
    }

    static func lines(_ area: KeyArea) -> String {
        guard let start = area.startLine else { return "Whole file" }
        let end = max(start, area.endLine ?? start)
        return end == start ? "Line \(start)" : "Lines \(start)–\(end)"
    }

    private func rows(_ nodes: [FileNode], depth: Int) -> [(node: FileNode, depth: Int)] {
        nodes.flatMap { node -> [(node: FileNode, depth: Int)] in
            guard let children = node.children, !collapsed.contains(node.id) else { return [(node, depth)] }
            return [(node, depth)] + rows(children, depth: depth + 1)
        }
    }

    private func folderRow(_ node: FileNode) -> some View {
        let isCollapsed = collapsed.contains(node.id)
        return HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: 12)
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { collapsed.formSymmetricDifference([node.id]) }
        .help(node.name)
    }

    /// Threads involving the viewer, per file.
    private var involvedThreads: [String: Int] {
        let threads = model.details[pr.id]?.threads.filter { $0.involves(model.viewer) } ?? []
        return Dictionary(grouping: threads, by: \.path).mapValues(\.count)
    }

    /// `involved`: shown instead of the comment count while the Involving Me filter is on.
    private func fileRow(_ file: FileChange, name: String, involved: Int? = nil) -> some View {
        let viewed = model.viewedFiles[pr.id]?.contains(file.filename) ?? false
        return HStack(spacing: 6) {
            if model.pending.contains("\(pr.id):\(file.filename)") {
                ProgressView().controlSize(.mini).frame(width: 14).help("Saving to GitHub…")
            } else {
                Toggle("Viewed", isOn: Binding(get: { viewed }, set: { _ in Task { await model.toggleViewed(file.filename, pr: pr) } }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(viewed ? "Viewed on GitHub. Uncheck to mark as not viewed." : "Mark as viewed on GitHub")
            }
            Image(systemName: icon(file.status)).foregroundStyle(color(file.status)).frame(width: 14)
            Text(name).lineLimit(1).truncationMode(.middle).foregroundStyle(viewed ? .secondary : .primary)
            Spacer()
            let comments = commentCount(file.filename)
            if involvedOnly, let involved {
                Label("\(involved)", systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                    .help("\(involved) thread\(involved == 1 ? "" : "s") involving you")
            } else if comments > 0 {
                Label("\(comments)", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
        }
        .help("\(file.filename)  +\(file.additions) −\(file.deletions)")
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
    var target: LineTarget?
    /// Sections the AI asked the reviewer to read, marked in the gutter.
    var keyAreas: [KeyArea] = []
    /// The key areas come from an older head: their lines may have moved, so they're marked dimmed.
    var keyAreasOutdated = false
    @AppStorage("wrapLines") private var wrap = false
    @AppStorage("involvedFilter") private var involvedOnly = false
    @ViewState private var composing: ReviewDeskCore.Anchor?
    @ViewState private var draftText = ""
    /// Lines whose comments the user folded away with the gutter bubble.
    @ViewState private var collapsed: Set<ReviewDeskCore.Anchor> = []
    /// The parsed and highlighted patch, rebuilt only when the patch or the mode changes, not on every redraw.
    @ViewState private var rendered: RenderedDiff?
    /// Shared horizontal offset of the code while soft wrap is off.
    @ViewState private var hScroll = HorizontalScroll(gutter: FileDiffView.numberWidth * 2 + FileDiffView.markerWidth)
    private static let numberWidth: CGFloat = 42
    private static let markerWidth: CGFloat = 20

    var body: some View {
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
                let key = RenderedDiff.Key(patch: patch, mode: mode, ink: ThemeStore.shared.ink)
                // Colors don't invalidate the cache: the old ones show until `onChange` renders again.
                let diff = rendered?.key.patch == patch && rendered?.key.mode == mode ? rendered : nil
                let commented = commentedAnchors
                let shownThreads = threads // once per redraw: `involves` runs a regex per thread
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let detached = shownThreads.filter { $0.line == nil }
                        if !detached.isEmpty {
                            Text("Comments on lines no longer in the diff").font(.caption).foregroundStyle(.secondary).padding([.top, .leading], 12)
                            ForEach(detached) { ThreadView(pr: pr, thread: $0, hidden: hiddenIDs) }
                        }
                        if let diff {
                            switch mode {
                            case .unified:
                                ForEach(diff.lines.indices, id: \.self) { index in
                                    let line = diff.lines[index]
                                    unifiedRow(line, change: diff.changes[index], text: diff.text, commented: commented)
                                    if let anchor = line.anchor(path: file.filename) {
                                        annotations(anchor, threads: shownThreads).padding(.leading, Self.numberWidth * 2 + Self.markerWidth)
                                    }
                                }
                            case .split:
                                ForEach(diff.rows.indices, id: \.self) { index in
                                    splitRow(diff.rows[index], text: diff.text, commented: commented)
                                    splitAnnotations(diff.rows[index], commented: commented, threads: shownThreads)
                                }
                            }
                        }
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                }
                .background(DiffColors.editor)
                .onHover { hScroll.hovering = $0 }
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { hScroll.paneWidth = $0 }
                .onChange(of: Pair(wrap ? 0 : CGFloat(diff?.longest ?? 0) * HorizontalScroll.charWidth + 32, mode), initial: true) { _, new in
                    hScroll.codeWidth = new.a
                    hScroll.columns = new.b == .split ? 2 : 1
                }
                .onAppear { hScroll.start() }
                .onDisappear { hScroll.stop() }
                .onChange(of: key, initial: true) { _, key in
                    rendered = RenderedDiff(key, path: file.filename)
                }
                .task(id: Pair(target?.id, diff != nil)) {
                    guard let target, let diff, let row = diff.row(for: target.line, side: target.side) else { return }
                    await Task.yield() // let the lazy stack lay out before jumping
                    withAnimation { proxy.scrollTo(row, anchor: .top) }
                }
                }
            } else {
                ContentUnavailableView("No diff available", systemImage: "doc.questionmark",
                                       description: Text("GitHub doesn't provide a diff for binary or very large files."))
            }
        }
    }

    private func isKey(_ line: DiffLine?) -> Bool {
        guard let line, line.kind != .removed, let number = line.newLine else { return false }
        return keyAreas.contains { $0.contains(line: number) }
    }

    private var allThreads: [ReviewThread] { model.details[pr.id]?.threads.filter { $0.path == file.filename } ?? [] }

    /// The threads shown: with Involving Me on, only those involving the viewer (the gutter still marks the others).
    private var threads: [ReviewThread] { allThreads.filter { !involvedOnly || $0.involves(model.viewer) } }

    private var hiddenIDs: Set<String> { Set(model.drafts(for: pr.id).compactMap(\.remoteID)) }

    /// Lines with threads or drafts, worked out once per redraw instead of once per row.
    private var commentedAnchors: Set<ReviewDeskCore.Anchor> {
        Set(allThreads.compactMap { thread in thread.line.map { ReviewDeskCore.Anchor(path: file.filename, line: $0, side: thread.side) } })
            .union(model.drafts(for: pr.id).map(\.anchor))
    }

    // MARK: Rows

    /// PyCharm layout: old code | old and new line numbers | new code.
    private func splitRow(_ row: DiffRow, text: [DiffLine: AttributedString], commented: Set<ReviewDeskCore.Anchor>) -> some View {
        let left = side(row.left, left: true), right = side(row.right, left: false)
        let leftColor = row.left == nil ? DiffColors.filler(row.change) : DiffColors.block(row.change, side: .left)
        let rightColor = row.right == nil ? DiffColors.filler(row.change) : DiffColors.block(row.change, side: .right)
        return Group {
            if let text = row.hunk {
                hunk(text)
            } else {
                HoverRow { hovered in
                    HStack(spacing: 0) {
                        code(row.left, text: text).background(leftColor)
                        HStack(spacing: 0) {
                            number(row.left?.oldLine).background(leftColor)
                            number(row.right?.newLine).background(rightColor)
                            marker(right ?? left, hovered: hovered, commented: commented).background(rightColor)
                        }
                        .overlay(alignment: .leading) { Rectangle().fill(DiffColors.separator).frame(width: 1) }
                        .overlay(alignment: .trailing) { Rectangle().fill(DiffColors.separator).frame(width: 1) }
                        code(row.right, text: text).background(rightColor)
                            .overlay(alignment: .leading) { if isKey(row.right) { keyBar } }
                    }
                }
            }
        }
    }

    private func unifiedRow(_ line: DiffLine, change: DiffChange?, text: [DiffLine: AttributedString],
                            commented: Set<ReviewDeskCore.Anchor>) -> some View {
        let anchor = line.anchor(path: file.filename)
        let color = DiffColors.block(change, side: line.kind == .removed ? .left : .right)
        return Group {
            if line.kind == .hunk {
                hunk(line.text)
            } else {
                HoverRow { hovered in
                    HStack(spacing: 0) {
                        number(line.oldLine)
                        number(line.newLine)
                        marker(anchor, hovered: hovered, commented: commented)
                        code(line, text: text)
                            .overlay(alignment: .leading) { if isKey(line) { keyBar } }
                    }
                    .background(color)
                }
            }
        }
    }

    /// Left half comments only on removed lines; context and added lines take comments on the right.
    private func side(_ line: DiffLine?, left: Bool) -> ReviewDeskCore.Anchor? {
        guard let line else { return nil }
        if left { return line.kind == .removed ? line.anchor(path: file.filename) : nil }
        return line.kind == .removed ? nil : line.anchor(path: file.filename)
    }

    /// Marks lines inside the AI's key areas.
    private var keyBar: some View {
        Rectangle().fill(DiffColors.keyArea.opacity(keyAreasOutdated ? 0.35 : 1)).frame(width: 3)
            .help(keyAreasOutdated ? "Key area from an analysis of an older commit: the lines may have moved since"
                                   : "Key area: read this before submitting")
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(DiffColors.lineNumber)
            .padding(.trailing, 6)
            .frame(width: Self.numberWidth, alignment: .trailing)
            .frame(maxHeight: .infinity)
    }

    /// Comment bubble when the line has comments, "+" on hover to add one.
    private func marker(_ anchor: ReviewDeskCore.Anchor?, hovered: Bool, commented: Set<ReviewDeskCore.Anchor>) -> some View {
        ZStack {
            if let anchor, commented.contains(anchor) {
                let folded = collapsed.contains(anchor)
                Button { collapsed.formSymmetricDifference([anchor]) } label: {
                    Image(systemName: folded ? "text.bubble" : "text.bubble.fill").foregroundStyle(DiffColors.lineNumber)
                }
                .buttonStyle(.plain)
                .help(folded ? "Show comments" : "Hide comments")
            } else if let anchor, hovered {
                Button {
                    draftText = ""
                    composing = anchor
                } label: {
                    Image(systemName: "plus.square.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Add a review comment")
            }
        }
        .frame(width: Self.markerWidth)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func code(_ line: DiffLine?, text: [DiffLine: AttributedString]) -> some View {
        Group {
            if let line {
                let code = Text(text[line] ?? AttributedString(line.text)).textSelection(.enabled)
                if wrap {
                    code.fixedSize(horizontal: false, vertical: true)
                } else {
                    // Full length over a one-line placeholder, so a long line scrolls instead of widening the row.
                    Text(" ").hidden().frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) { ScrolledLine(scroll: hScroll) { code.fixedSize() } }
                }
            } else {
                Text(" ")
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle()) // clipping doesn't stop a scrolled line taking clicks meant for the gutter or the other half
    }

    /// `tokens` come from the whole diff, so strings opened on earlier lines (docstrings) keep their color.
    static func highlighted(_ text: String, tokens: [SyntaxToken]) -> AttributedString {
        var result = AttributedString(text.isEmpty ? " " : text)
        result.foregroundColor = DiffColors.text
        for token in tokens {
            let start = result.index(result.startIndex, offsetByCharacters: token.range.lowerBound)
            let end = result.index(result.startIndex, offsetByCharacters: token.range.upperBound)
            result[start..<end].foregroundColor = DiffColors.syntax(token.kind)
            if token.kind == .comment { result[start..<end].font = .system(size: 12.5, design: .monospaced).italic() }
        }
        return result
    }

    /// Unchanged lines between hunks are skipped, like PyCharm's folded regions.
    private func hunk(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis").foregroundStyle(DiffColors.lineNumber)
            Text(text).foregroundStyle(DiffColors.lineNumber).lineLimit(1)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 4)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffColors.fold)
    }

    // MARK: Inline comments

    /// Comments sit under the pane of the side they're anchored to, like PyCharm.
    @ViewBuilder
    private func splitAnnotations(_ row: DiffRow, commented: Set<ReviewDeskCore.Anchor>, threads: [ReviewThread]) -> some View {
        let left = side(row.left, left: true), right = side(row.right, left: false)
        let shown = { (anchor: ReviewDeskCore.Anchor?) in anchor.map { commented.contains($0) || composing == $0 } ?? false }
        if shown(left) || shown(right) {
            HStack(alignment: .top, spacing: 0) {
                annotationColumn(left, threads: threads)
                Color.clear.frame(width: Self.numberWidth * 2 + Self.markerWidth)
                annotationColumn(right, threads: threads)
            }
        }
    }

    private func annotationColumn(_ anchor: ReviewDeskCore.Anchor?, threads: [ReviewThread]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let anchor { annotations(anchor, threads: threads) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func annotations(_ anchor: ReviewDeskCore.Anchor, threads: [ReviewThread]) -> some View {
        if !collapsed.contains(anchor) {
            ForEach(threads.filter { $0.line == anchor.line && $0.side == anchor.side }) {
                ThreadView(pr: pr, thread: $0, hidden: hiddenIDs).font(.body)
            }
            ForEach(model.drafts(for: pr.id).filter { $0.anchor == anchor }) {
                DraftView(pr: pr, draft: $0).font(.body)
            }
        }
        if composing == anchor {
            CommentComposer(text: $draftText, placeholder: "Add a review comment", submitTitle: "Add to Review",
                            onCancel: { composing = nil }) {
                model.addDraft(pr, anchor: anchor, body: draftText)
                composing = nil
            }
            .font(.body)
            .padding(10)
            .modifier(ThreadBox(accent: DiffColors.draft))
        }
    }
}

/// A file's patch parsed, paired for side by side and syntax-highlighted once. Rebuilding this on every
/// redraw (each hover used to cause one) made large files stutter while scrolling.
struct RenderedDiff {
    struct Key: Equatable {
        var patch: String
        var mode: DiffMode
        /// The theme colors baked into `text`, so changing one renders again.
        var ink: [HexColor?]
    }

    var key: Key
    var mode: DiffMode { key.mode }
    var lines: [DiffLine]
    /// Index-aligned with `lines`.
    var changes: [DiffChange?]
    /// Empty in unified mode.
    var rows: [DiffRow]
    var text: [DiffLine: AttributedString]
    /// Characters in the longest line, a tab counted as 4.
    var longest: Int

    @MainActor init(_ key: Key, path: String) {
        let lines = Diff.parse(key.patch)
        let syntax = Syntax.language(for: path).map { Syntax.tokens(diff: lines, language: $0) } ?? [:]
        var text: [DiffLine: AttributedString] = [:]
        for line in lines where line.kind != .hunk {
            text[line] = FileDiffView.highlighted(line.text, tokens: syntax[line] ?? [])
        }
        (self.key, self.lines, self.text) = (key, lines, text)
        changes = Diff.changes(lines)
        longest = lines.map { $0.text.count + $0.text.count { $0 == "\t" } * 3 }.max() ?? 0
        rows = key.mode == .split ? Diff.sideBySide(lines) : []
    }

    /// Offset of the first diff row at or after a line of `side`, matching the ForEach ids.
    func row(for line: Int, side: DiffSide) -> Int? {
        switch (mode, side) {
        case (.unified, .right): lines.firstIndex { $0.kind != .removed && ($0.newLine ?? 0) >= line }
        case (.unified, .left): lines.firstIndex { $0.kind != .added && ($0.oldLine ?? 0) >= line }
        case (.split, .right): rows.firstIndex { ($0.right?.newLine ?? 0) >= line }
        case (.split, .left): rows.firstIndex { ($0.left?.oldLine ?? 0) >= line }
        }
    }
}

/// Keeps the pointer's hover state inside one row, so moving over the diff redraws that row only.
private struct HoverRow<Content: View>: View {
    @ViewState private var hovered = false
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(hovered).onHover { hovered = $0 }
    }
}

/// Horizontal offset shared by every code cell while soft wrap is off, so long lines scroll together like in an
/// editor. Only the cells that read `x` redraw while scrolling; numbers, markers and comments stay put.
@Observable @MainActor
final class HorizontalScroll {
    static let charWidth = ("M" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)]).width

    var x: CGFloat = 0
    /// What `limit` comes from, set by layout without redrawing anything: the code's full width (0 while wrapping),
    /// the diff pane's width, and how many code columns share it with the gutter.
    @ObservationIgnored var codeWidth: CGFloat = 0 { didSet { clamp() } }
    @ObservationIgnored var paneWidth: CGFloat = 0 { didSet { clamp() } }
    @ObservationIgnored var columns: CGFloat = 1 { didSet { clamp() } }
    private let gutter: CGFloat

    init(gutter: CGFloat) { self.gutter = gutter }

    /// How far the widest line reaches past its code column.
    var limit: CGFloat { max(0, codeWidth - (paneWidth - gutter) / columns) }

    private func clamp() { if x > limit { x = limit } }
    @ObservationIgnored var hovering = false
    @ObservationIgnored private var monitor: Any?

    // ponytail: trackpad and (shift-)wheel only, no visible scroller, and dragging a selection past the edge
    // doesn't scroll; add an NSScroller if people miss it.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let (dx, dy, precise) = (event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
            MainActor.assumeIsolated {
                guard let self, self.hovering, abs(dx) > abs(dy) else { return }
                self.x = min(max(0, self.x - (precise ? dx : dx * Self.charWidth * 3)), self.limit)
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct ScrolledLine<Content: View>: View {
    let scroll: HorizontalScroll
    @ViewBuilder let content: Content

    var body: some View { content.offset(x: -scroll.x) }
}

/// Two values as one `task(id:)`.
private struct Pair<A: Equatable, B: Equatable>: Equatable {
    var a: A
    var b: B
    init(_ a: A, _ b: B) { (self.a, self.b) = (a, b) }
}
