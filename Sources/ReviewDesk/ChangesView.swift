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
            if let files = model.files[pr.id] {
                HSplitView {
                    FileTree(pr: pr, files: files, selection: $selectedPath) { path, line in
                        selectedPath = path
                        target = line.map { LineTarget(path: path, line: $0) }
                    }
                        .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)
                    Group {
                        if let file = files.first(where: { $0.filename == selectedPath }) ?? files.first {
                            FileDiffView(pr: pr, file: file, mode: mode, target: target?.path == file.filename ? target : nil,
                                         keyAreas: model.keyAreasRun(for: pr)?.result.keyAreas.filter { $0.path == file.filename } ?? [])
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
    }
}

/// A line to scroll to; a fresh id lets the same section be revisited.
struct LineTarget: Equatable {
    var path: String
    var line: Int
    var id = UUID()
}

// MARK: - Review bar

struct ReviewBar: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    @Binding var mode: DiffMode
    @AppStorage("wrapLines") private var wrap = false
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

    var body: some View {
        let focus = model.focus(for: pr)
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
                    ForEach(rows(FileNode.tree(files), depth: 0), id: \.node.id) { row in
                        if let file = row.node.file {
                            fileRow(file, name: row.node.name)
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
        } else if let run = model.keyAreasRun(for: pr), run.headRefOid != pr.headRefOid {
            Label("Key areas are from an older commit; lines may have moved.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        ForEach(focus, id: \.path) { item in
            if let file = files.first(where: { $0.filename == item.path }) {
                fileRow(file, name: item.path).tag(file.filename)
                ForEach(Array(item.areas.enumerated()), id: \.offset) { _, area in
                    Button { openArea(item.path, area.startLine) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.lines(area)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(area.reason).font(.caption).lineLimit(3).multilineTextAlignment(.leading)
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

    private func fileRow(_ file: FileChange, name: String) -> some View {
        let viewed = model.viewedFiles[pr.id]?.contains(file.filename) ?? false
        return HStack(spacing: 6) {
            Toggle("Viewed", isOn: Binding(get: { viewed }, set: { _ in Task { await model.toggleViewed(file.filename, pr: pr) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(viewed ? "Viewed on GitHub. Uncheck to mark as not viewed." : "Mark as viewed on GitHub")
            Image(systemName: icon(file.status)).foregroundStyle(color(file.status)).frame(width: 14)
            Text(name).lineLimit(1).truncationMode(.middle).foregroundStyle(viewed ? .secondary : .primary)
            Spacer()
            let comments = commentCount(file.filename)
            if comments > 0 {
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
    @AppStorage("wrapLines") private var wrap = false
    @ViewState private var hovered: ReviewDeskCore.Anchor?
    @ViewState private var composing: ReviewDeskCore.Anchor?
    @ViewState private var draftText = ""
    /// Lines whose comments the user folded away with the gutter bubble.
    @ViewState private var collapsed: Set<ReviewDeskCore.Anchor> = []
    private static let numberWidth: CGFloat = 42
    private static let markerWidth: CGFloat = 20

    var body: some View {
        let language = Syntax.language(for: file.filename)
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
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let detached = threads.filter { $0.line == nil }
                        if !detached.isEmpty {
                            Text("Comments on lines no longer in the diff").font(.caption).foregroundStyle(.secondary).padding([.top, .leading], 12)
                            ForEach(detached) { ThreadView(pr: pr, thread: $0, hidden: hiddenIDs) }
                        }
                        let lines = Diff.parse(patch)
                        let syntax = language.map { Syntax.tokens(diff: lines, language: $0) } ?? [:]
                        switch mode {
                        case .unified:
                            let changes = Diff.changes(lines)
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                unifiedRow(line, change: changes[index], syntax: syntax)
                                if let anchor = line.anchor(path: file.filename) {
                                    annotations(anchor).padding(.leading, Self.numberWidth * 2 + Self.markerWidth)
                                }
                            }
                        case .split:
                            ForEach(Array(Diff.sideBySide(lines).enumerated()), id: \.offset) { _, row in
                                splitRow(row, syntax: syntax)
                                splitAnnotations(row)
                            }
                        }
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                }
                .background(DiffColors.editor)
                .task(id: target?.id) {
                    guard let line = target?.line, let row = row(for: line, patch: patch) else { return }
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

    /// Offset of the first diff row at or after a new-side line, matching the ForEach ids below.
    private func row(for line: Int, patch: String) -> Int? {
        let lines = Diff.parse(patch)
        switch mode {
        case .unified: return lines.firstIndex { $0.kind != .removed && ($0.newLine ?? 0) >= line }
        case .split: return Diff.sideBySide(lines).firstIndex { ($0.right?.newLine ?? 0) >= line }
        }
    }

    private func isKey(_ line: DiffLine?) -> Bool {
        guard let line, line.kind != .removed, let number = line.newLine else { return false }
        return keyAreas.contains { $0.contains(line: number) }
    }

    private var threads: [ReviewThread] { model.details[pr.id]?.threads.filter { $0.path == file.filename } ?? [] }

    private var hiddenIDs: Set<String> { Set(model.drafts(for: pr.id).compactMap(\.remoteID)) }

    // MARK: Rows

    /// PyCharm layout: old code | old and new line numbers | new code.
    private func splitRow(_ row: DiffRow, syntax: [DiffLine: [SyntaxToken]]) -> some View {
        let left = side(row.left, left: true), right = side(row.right, left: false)
        let leftColor = row.left == nil ? DiffColors.filler(row.change) : DiffColors.block(row.change, side: .left)
        let rightColor = row.right == nil ? DiffColors.filler(row.change) : DiffColors.block(row.change, side: .right)
        return Group {
            if let text = row.hunk {
                hunk(text)
            } else {
                HStack(spacing: 0) {
                    code(row.left, syntax: syntax).background(leftColor)
                    HStack(spacing: 0) {
                        number(row.left?.oldLine).background(leftColor)
                        number(row.right?.newLine).background(rightColor)
                        marker(right ?? left).background(rightColor)
                    }
                    .overlay(alignment: .leading) { Rectangle().fill(DiffColors.separator).frame(width: 1) }
                    .overlay(alignment: .trailing) { Rectangle().fill(DiffColors.separator).frame(width: 1) }
                    code(row.right, syntax: syntax).background(rightColor)
                        .overlay(alignment: .leading) { if isKey(row.right) { keyBar } }
                }
                .onHover { track(right ?? left, $0) }
            }
        }
    }

    private func unifiedRow(_ line: DiffLine, change: DiffChange?, syntax: [DiffLine: [SyntaxToken]]) -> some View {
        let anchor = line.anchor(path: file.filename)
        let color = DiffColors.block(change, side: line.kind == .removed ? .left : .right)
        return Group {
            if line.kind == .hunk {
                hunk(line.text)
            } else {
                HStack(spacing: 0) {
                    number(line.oldLine)
                    number(line.newLine)
                    marker(anchor)
                    code(line, syntax: syntax)
                        .overlay(alignment: .leading) { if isKey(line) { keyBar } }
                }
                .background(color)
                .onHover { track(anchor, $0) }
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
        Rectangle().fill(Color.yellow.opacity(0.85)).frame(width: 3).help("Key area: read this before submitting")
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(DiffColors.lineNumber)
            .padding(.trailing, 6)
            .frame(width: Self.numberWidth, alignment: .trailing)
            .frame(maxHeight: .infinity)
    }

    /// Comment bubble when the line has comments, "+" on hover to add one.
    private func marker(_ anchor: ReviewDeskCore.Anchor?) -> some View {
        ZStack {
            if let anchor, hasComments(anchor) {
                let folded = collapsed.contains(anchor)
                Button { collapsed.formSymmetricDifference([anchor]) } label: {
                    Image(systemName: folded ? "text.bubble" : "text.bubble.fill").foregroundStyle(DiffColors.lineNumber)
                }
                .buttonStyle(.plain)
                .help(folded ? "Show comments" : "Hide comments")
            } else if let anchor, hovered == anchor {
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
    private func code(_ line: DiffLine?, syntax: [DiffLine: [SyntaxToken]]) -> some View {
        Group {
            if let line {
                Text(Self.highlighted(line.text, tokens: syntax[line] ?? []))
                    .lineLimit(wrap ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(" ")
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
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

    private func track(_ anchor: ReviewDeskCore.Anchor?, _ inside: Bool) {
        if inside { hovered = anchor } else if hovered == anchor { hovered = nil }
    }

    // MARK: Inline comments

    private func hasComments(_ anchor: ReviewDeskCore.Anchor) -> Bool {
        threads.contains { $0.line == anchor.line && $0.side == anchor.side }
            || model.drafts(for: pr.id).contains { $0.anchor == anchor }
    }

    /// Comments sit under the pane of the side they're anchored to, like PyCharm.
    @ViewBuilder
    private func splitAnnotations(_ row: DiffRow) -> some View {
        let left = side(row.left, left: true), right = side(row.right, left: false)
        let shown = { (anchor: ReviewDeskCore.Anchor?) in anchor.map { hasComments($0) || composing == $0 } ?? false }
        if shown(left) || shown(right) {
            HStack(alignment: .top, spacing: 0) {
                annotationColumn(left)
                Color.clear.frame(width: Self.numberWidth * 2 + Self.markerWidth)
                annotationColumn(right)
            }
        }
    }

    private func annotationColumn(_ anchor: ReviewDeskCore.Anchor?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let anchor { annotations(anchor) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func annotations(_ anchor: ReviewDeskCore.Anchor) -> some View {
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
            .modifier(ThreadBox(accent: .accentColor))
        }
    }
}

/// PyCharm New UI diff palette, adapting to light and dark appearance.
enum DiffColors {
    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let editor = dynamic(dark: 0x1E1F22, light: 0xFFFFFF)
    static let text = dynamic(dark: 0xBCBEC4, light: 0x080808)
    static let lineNumber = dynamic(dark: 0x6F737A, light: 0xAEB3C2)
    static let separator = dynamic(dark: 0x393B40, light: 0xEBECF0)
    static let fold = dynamic(dark: 0x2B2D30, light: 0xF2F3F5)
    static let modified = dynamic(dark: 0x283A4A, light: 0xDBE8FB)
    static let added = dynamic(dark: 0x294436, light: 0xDCF0DC)
    static let removed = dynamic(dark: 0x3C3F44, light: 0xE6E7EA)

    enum Side { case left, right }

    static func block(_ change: DiffChange?, side: Side) -> Color {
        switch change {
        case .modified: modified
        case .added: added
        case .removed: removed
        case nil: .clear
        }
    }

    /// The empty side of an added or removed block: a faint version of the block color.
    static func filler(_ change: DiffChange?) -> Color {
        block(change, side: .left).opacity(0.45)
    }

    static func syntax(_ kind: SyntaxKind) -> Color {
        switch kind {
        case .keyword: dynamic(dark: 0xCF8E6D, light: 0x0033B3)
        case .string: dynamic(dark: 0x6AAB73, light: 0x067D17)
        case .comment: dynamic(dark: 0x7A7E85, light: 0x8C8C8C)
        case .number: dynamic(dark: 0x2AACB8, light: 0x1750EB)
        case .call: dynamic(dark: 0x56A8F5, light: 0x00627A)
        }
    }
}
