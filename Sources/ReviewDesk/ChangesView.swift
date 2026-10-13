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
    @AppStorage("focusFilter") private var focusOnly = false
    @AppStorage("involvedFilter") private var involvedOnly = false
    @ViewState private var selection: ChangesItem?
    @ViewState private var target: LineTarget?

    var body: some View {
        // Some commits instead of the whole PR: their comparison, or the whole diff when GitHub can't make it.
        let bounds = model.commitSelection(for: pr).bounds(commits: model.details[pr.id]?.commits ?? [], pr: pr)
        let key = bounds.map { AppModel.comparisonKey(pr, base: $0.base, head: $0.head) }
        let missing = key.flatMap { model.missingComparisons[$0] }
        let shown = key.flatMap { missing == nil ? $0 : nil }
        let changed = if let shown { model.comparisons[shown] } else { model.files[pr.id] }
        let linesMoved = shown != nil && bounds?.head != pr.headRefOid
        let notice = missing ?? (shown != nil && (changed?.count ?? 0) >= 300
            ? "GitHub lists at most 300 files when comparing commits, so some may be missing here." : nil)
        VStack(spacing: 0) {
            ReviewBar(pr: pr, mode: $mode)
            Divider()
            let analysis = model.keyAreasRun(for: pr)
            if let analysis, analysis.isOutdated(for: pr) {
                OutdatedAnalysisBanner(pr: pr, run: analysis).padding(8)
                Divider()
            }
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            if let files = changed {
                HSplitView {
                    FileTree(pr: pr, files: files, selection: $selection, showsCommits: shown != nil, linesMoved: linesMoved)
                        .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)
                    Group {
                        if let file = files.first(where: { $0.filename == selection?.path }) ?? files.first {
                            let commitView = shown == nil ? nil : CommitView(
                                endsAtHead: bounds?.head == pr.headRefOid,
                                // Only from the PR diff at this head: an older list's lines may have moved.
                                prAnchors: model.filesHead[pr.id] != pr.headRefOid ? []
                                    : model.files[pr.id]?.first { $0.filename == file.filename }?.patch
                                        .map { Diff.anchors(path: file.filename, patch: $0) } ?? [])
                            let areas = commitView?.endsAtHead == false ? [] : keyAreas(file.filename)
                            // An added or deleted file has one empty side: show it full width.
                            FileDiffView(pr: pr, file: file, mode: ["added", "removed"].contains(file.status) ? .unified : mode, target: target?.path == file.filename ? target : nil,
                                         keyAreas: areas, selectedArea: selectedArea(in: areas),
                                         keyAreasOutdated: analysis?.isOutdated(for: pr) == true,
                                         commitView: commitView, fileStep: fileStep(files, current: file),
                                         selectArea: { selection = .area(file.filename, $0) })
                                .id(file.filename + (shown ?? ""))
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
        .task(id: key) { if let bounds { await model.loadComparison(pr, base: bounds.base, head: bounds.head) } }
        .task(id: shown.map { _ in pr.headRefOid }) {
            // A commit view after a push: refresh the PR diff its comments are anchored to.
            if shown != nil, model.filesHead[pr.id] != pr.headRefOid { await model.loadFiles(pr) }
        }
        .onChange(of: model.changesTarget?.id, initial: true) {
            // Sent here from another tab (e.g. Risk): open the file and, when there's a line, scroll to it.
            guard let next = model.changesTarget else { return }
            let areas = keyAreas(next.path)
            let area = areas.firstIndex { next.line > 0 && next.side == .right && $0.startLine == next.line }
            selection = area.map { .area(next.path, $0) } ?? .file(next.path)
            target = next.line > 0 ? LineTarget(path: next.path, line: next.line, endLine: area.flatMap { areas[$0].endLine }, side: next.side) : nil
            model.changesTarget = nil
        }
        .onChange(of: model.keyAreasRun(for: pr)?.result.keyAreas) {
            // A new review renumbers the areas: keep the file open rather than another area.
            if case .area(let path, _)? = selection { selection = .file(path) }
        }
        .onChange(of: selection) {
            switch selection {
            case .area(let path, let index)?:
                guard !linesMoved else { target = nil; break }
                target = keyAreas(path).dropFirst(index).first.map { LineTarget(path: path, line: $0.startLine ?? 0, endLine: $0.endLine) }
            case .file(let path)?:
                // A jump left over from an earlier visit would otherwise replay when the file is shown again.
                if target?.path != path { target = nil }
            case nil:
                target = nil
            }
        }
    }

    /// The file's key areas from the latest AI review, in the order the file list shows them.
    private func keyAreas(_ path: String) -> [KeyArea] {
        model.keyAreasRun(for: pr)?.result.keyAreas.filter { $0.path == path } ?? []
    }

    /// Previous/next file in the order the file list shows them: the tree (narrowed by Involving Me), or the Focus list.
    private func fileStep(_ files: [FileChange], current: FileChange) -> StepControl {
        let order = {
            focusOnly ? model.focus(for: pr).map(\.path)
                : FileNode.paths(FileNode.tree(FileTree.listed(files, involved: model.involvedThreads(pr), involvedOnly: involvedOnly)))
        }
        return StepControl(noun: "file", modifiers: .command,
                           state: { let order = order(); return (Array(order.indices), order.firstIndex(of: selection?.path ?? current.filename)) },
                           go: { selection = .file(order()[$0]) })
    }

    private func selectedArea(in areas: [KeyArea]) -> KeyArea? {
        guard case .area(_, let index)? = selection, areas.indices.contains(index) else { return nil }
        return areas[index]
    }
}

/// A row of the file list: a file, or one of its key areas (an index into the file's areas).
enum ChangesItem: Hashable {
    case file(String)
    case area(String, Int)

    var path: String {
        switch self {
        case .file(let path), .area(let path, _): path
        }
    }
}

/// A line to scroll to; a fresh id lets the same section be revisited.
struct LineTarget: Equatable {
    var path: String
    /// 0 for the top of the file.
    var line: Int
    /// The last line of a key area; the jump lands on the first of `line...endLine` that's in the diff.
    var endLine: Int?
    /// Left: `line` is in the old file, as for comments on removed lines.
    var side = DiffSide.right
    var id = UUID()
}

/// "⌃ File 2 of 9 ⌄": previous/next buttons with [ and ] shortcuts, shared by files, comments and key areas.
struct StepControl: View {
    let noun: String
    let modifiers: EventModifiers
    /// Where each step can land (list indices or diff rows), in any order, and where we are. A closure, so a step
    /// reads the state at the time of the key press: a shortcut's action can outlive the redraw that made it.
    let state: () -> (positions: [Int], current: Int?)
    let go: (Int) -> Void

    var body: some View {
        let (positions, current) = state()
        let back = Navigation.step(positions, from: current, forward: false)
        let next = Navigation.step(positions, from: current, forward: true)
        let count = Set(positions).count
        HStack(spacing: 2) {
            Button { step(forward: false) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut("[", modifiers: modifiers)
                .disabled(back == nil)
                .help("Previous \(noun) (\(keys)[)")
            Text(current.flatMap { Set(positions).sorted().firstIndex(of: $0) }.map { "\(noun.prefix(1).uppercased() + noun.dropFirst()) \($0 + 1) of \(count)" }
                 ?? "\(count) \(noun)\(count == 1 ? "" : "s")")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button { step(forward: true) } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut("]", modifiers: modifiers)
                .disabled(next == nil)
                .help("Next \(noun) (\(keys)])")
        }
        .buttonStyle(.borderless)
        .disabled(count == 0)
    }

    private func step(forward: Bool) {
        let (positions, current) = state()
        Navigation.step(positions, from: current, forward: forward).map(go)
    }

    private var keys: String {
        [(EventModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined()
    }
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
            if let commits = model.details[pr.id]?.commits, !commits.isEmpty {
                CommitPicker(pr: pr, commits: commits)
            }
            MyReviewStatus(pr: pr, compact: true)
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

/// GitHub's "Changes from" menu: all commits, those since the viewer's review, or one commit or a run of them.
struct CommitPicker: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let commits: [PRCommit]
    @ViewState private var open = false

    var body: some View {
        let selection = model.commitSelection(for: pr)
        Button { open = true } label: {
            Label(title(selection), systemImage: "smallcircle.filled.circle").lineLimit(1).frame(maxWidth: 260)
        }
        .help("Review all the changes, those since your last review, or one commit or a range of them")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                option("All commits", .all, selection)
                if pr.viewerReviewedOid.map({ $0 != pr.headRefOid }) == true {
                    option("Since your last review", .sinceReview, selection)
                }
                Divider()
                Text("Click a commit, or Shift-click another to pick a range.").font(.caption).foregroundStyle(.secondary)
                List(selection: range(selection)) {
                    ForEach(commits) { commit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.headline).lineLimit(1)
                            Text("\(commit.abbreviatedOid) · \(commit.author)\(commit.date.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(commit.oid)
                    }
                }
                .frame(height: min(CGFloat(commits.count) * 40 + 12, 360))
            }
            .padding(12)
            .frame(width: 440)
        }
    }

    private func option(_ title: String, _ value: CommitSelection, _ selection: CommitSelection) -> some View {
        Button {
            model.selectCommits(value, pr: pr)
            open = false
        } label: {
            Label(title, systemImage: "checkmark").labelStyle(CheckLabel(checked: value == selection))
        }
        .buttonStyle(.plain)
    }

    /// The selected run as list rows; any multi-selection becomes the run from its oldest to its newest commit.
    private func range(_ selection: CommitSelection) -> Binding<Set<String>> {
        Binding {
            guard case .range(let first, let last) = selection,
                  let start = commits.firstIndex(where: { $0.oid == first }), let end = commits.firstIndex(where: { $0.oid == last }) else { return [] }
            return Set(commits[start...end].map(\.oid))
        } set: { oids in
            let picked = commits.indices.filter { oids.contains(commits[$0].oid) }
            guard let start = picked.first, let end = picked.last else { return model.selectCommits(.all, pr: pr) }
            model.selectCommits(.range(first: commits[start].oid, last: commits[end].oid), pr: pr)
        }
    }

    private func title(_ selection: CommitSelection) -> String {
        guard case .range(let first, let last) = selection,
              let start = commits.firstIndex(where: { $0.oid == first }), let end = commits.firstIndex(where: { $0.oid == last }) else {
            return selection == .sinceReview ? "Since your last review" : "All commits"
        }
        return start == end ? "\(commits[start].abbreviatedOid) \(commits[start].headline)"
            : "\(end - start + 1) commits: \(commits[start].abbreviatedOid)…\(commits[end].abbreviatedOid)"
    }
}

/// A checkmark that keeps its space when hidden, so options line up.
private struct CheckLabel: LabelStyle {
    var checked: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.opacity(checked ? 1 : 0)
            configuration.title
        }
        .contentShape(Rectangle())
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

    /// File paths in the order the tree lists them, collapsed folders included.
    static func paths(_ nodes: [FileNode]) -> [String] {
        nodes.flatMap { node in node.file.map { [$0.filename] } ?? paths(node.children ?? []) }
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
    /// Key area rows are selectable too, so the list shows which one is open and arrow keys reach them.
    @Binding var selection: ChangesItem?
    /// Some commits are shown: Viewed marks a file in the whole pull request, so it's left alone here.
    var showsCommits = false
    /// The commits shown end before the head: key areas' line numbers don't apply.
    var linesMoved = false
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
                    ForEach(rows(FileNode.tree(Self.listed(files, involved: involved, involvedOnly: involvedOnly)), depth: 0), id: \.node.id) { row in
                        if let file = row.node.file {
                            fileRow(file, name: row.node.name, involved: involved[file.filename])
                                .padding(.leading, CGFloat(row.depth) * 14 + 16)
                                .tag(ChangesItem.file(file.filename))
                        } else {
                            folderRow(row.node)
                                .padding(.leading, CGFloat(row.depth) * 14)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .onAppear { if selection == nil { selection = files.first.map { .file($0.filename) } } }
    }

    @ViewBuilder
    private func focusRows(_ focus: [FocusFile]) -> some View {
        if focus.isEmpty {
            Text("Run an AI review to list the key files to read. Files with comments you haven't submitted show here too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(focus, id: \.path) { item in
            if let file = files.first(where: { $0.filename == item.path }) {
                fileRow(file, name: item.path).tag(ChangesItem.file(file.filename))
                // Ids unique across files: offsets alone repeat in every file, and the list then mixed up their rows.
                ForEach(item.areas.enumerated().map { (ChangesItem.area(item.path, $0.offset), $0.element) }, id: \.0) { tag, area in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.lines(area) + (area.question.map { " · \($0.label)" } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(inlineMarkdown(area.reason)).font(.caption).lineLimit(3).multilineTextAlignment(.leading)
                    }
                    .padding(.leading, 22)
                    .tag(tag)
                    .disabled(linesMoved)
                    .help(linesMoved ? "These lines are in the latest commit: pick All commits, or a range ending at it, to jump there"
                          : area.startLine == nil ? "Open the file" : "Jump to these lines")
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

    private var involvedThreads: [String: Int] { model.involvedThreads(pr) }

    /// The files the tree lists: with Involving Me on, only those with a thread involving the viewer (all when none has).
    static func listed(_ files: [FileChange], involved: [String: Int], involvedOnly: Bool) -> [FileChange] {
        involvedOnly && !involved.isEmpty ? files.filter { involved[$0.filename] != nil } : files
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
                    .disabled(showsCommits)
                    .help(showsCommits ? "Viewed applies to the whole pull request: pick All commits to change it"
                          : viewed ? "Viewed on GitHub. Uncheck to mark as not viewed." : "Mark as viewed on GitHub")
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
        .contextMenu {
            Button("Open in Editor") { Task { await model.openInEditor(pr, file: file) } }
                .disabled(file.status == "removed")
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
    var target: LineTarget?
    /// Sections the AI asked the reviewer to read, marked in the gutter.
    var keyAreas: [KeyArea] = []
    /// The key area picked in the file list, marked more strongly than the others.
    var selectedArea: KeyArea?
    /// The key areas come from an older head: their lines may have moved, so they're marked dimmed.
    var keyAreasOutdated = false
    /// Set when Changes shows some commits: comments go only where they map onto the whole PR's diff.
    var commitView: CommitView?
    var fileStep: StepControl?
    /// Selects the key area at this index in the file list, which scrolls the diff to it.
    var selectArea: (Int) -> Void = { _ in }
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
    /// The row the last jump landed on: comment steps go on from there.
    @ViewState private var cursor: Int?
    @ViewState private var jump: Jump?
    @ViewState private var jumpedTarget: UUID?
    /// Scroll id of the top of the file, above comments on lines no longer in the diff.
    private static let top = -1
    private static let numberWidth: CGFloat = 42
    private static let markerWidth: CGFloat = 20

    var body: some View {
        let shownThreads = threads // once per redraw: `involves` runs a regex per thread
        let withComments = commentRows(shownThreads)
        let areaRowsNow = areaRows
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(file.filename).font(.callout.monospaced()).textSelection(.enabled)
                Text("+\(file.additions)").foregroundStyle(.green).font(.callout.monospacedDigit())
                Text("−\(file.deletions)").foregroundStyle(.red).font(.callout.monospacedDigit())
                Spacer()
                if let target, target.line > 0, let diff = currentDiff, diff.row(for: target) == nil {
                    let end = max(target.line, target.endLine ?? target.line)
                    Label(end > target.line ? "Lines \(target.line)–\(end) aren't in this diff" : "Line \(target.line) isn't in this diff",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                        .help("The key area starts after the last changed lines, or comes from an older commit")
                }
                Button("Open in Editor") { Task { await model.openInEditor(pr, file: file, line: target?.line) } }
                    .controlSize(.small)
                    .disabled(file.status == "removed")
                    .help("Open this file from the local clone in your editor, at the line shown or else at the first change")
                if !withComments.isEmpty {
                    StepControl(noun: "comment", modifiers: [.command, .option], state: { (Array(withComments.keys), cursor) }) { row in
                        collapsed.subtract(withComments[row] ?? []) // show the comments you jump to, if they were folded
                        jump = Jump(row: row)
                    }
                }
                if areaRowsNow.contains(where: { $0 != nil }) {
                    StepControl(noun: "key area", modifiers: [.command, .control], state: { (areaRowsNow.compactMap { $0 }, cursor) }) { row in
                        if let index = areaRowsNow.firstIndex(of: row) { selectArea(index) }
                        jump = Jump(row: row) // also when that area is already selected, after a jump elsewhere
                    }
                }
                fileStep
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            if let patch = file.patch {
                let key = RenderedDiff.Key(patch: patch, mode: mode, ink: ThemeStore.shared.ink)
                let diff = currentDiff
                let commented = commentedAnchors
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.top)
                        let detached = shownThreads.filter { $0.line == nil }
                        if !detached.isEmpty {
                            Text("Comments on lines no longer in the diff").font(.caption).foregroundStyle(.secondary).padding([.top, .leading], 12)
                            ForEach(detached) { ThreadView(pr: pr, thread: $0, hidden: hiddenIDs) }
                        }
                        if let diff {
                            switch mode {
                            case .unified:
                                // One view per id, so a jump lands on the line and not on its comments.
                                ForEach(diff.lines.indices, id: \.self) { index in
                                    let line = diff.lines[index]
                                    VStack(alignment: .leading, spacing: 0) {
                                        unifiedRow(line, change: diff.changes[index], text: diff.text, commented: commented)
                                        if let anchor = line.anchor(path: file.filename) {
                                            annotations(anchor, threads: shownThreads).padding(.leading, Self.numberWidth * 2 + Self.markerWidth)
                                        }
                                    }
                                }
                            case .split:
                                ForEach(diff.rows.indices, id: \.self) { index in
                                    VStack(alignment: .leading, spacing: 0) {
                                        splitRow(diff.rows[index], text: diff.text, commented: commented)
                                        splitAnnotations(diff.rows[index], commented: commented, threads: shownThreads)
                                    }
                                }
                            }
                        }
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                }
                .background(DiffColors.editor)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { hScroll.frame = $0 }
                .onChange(of: Pair(wrap ? 0 : (diff?.widest ?? 0) + 32, mode), initial: true) { _, new in
                    hScroll.codeWidth = new.a
                    hScroll.columns = new.b == .split ? 2 : 1
                }
                .onAppear { hScroll.start() }
                .onDisappear { hScroll.stop() }
                .onChange(of: key, initial: true) { _, key in
                    rendered = RenderedDiff(key, path: file.filename)
                    cursor = nil // rows differ between the two layouts
                }
                .task(id: Pair(target?.id, diff != nil)) {
                    // Each target jumps once: switching layout re-renders the diff but mustn't pull you back to it.
                    guard let target, target.id != jumpedTarget, let diff,
                          let row = target.line > 0 ? diff.row(for: target) : Self.top else { return }
                    jumpedTarget = target.id
                    jump = Jump(row: row)
                }
                .task(id: jump?.id) {
                    guard let row = jump?.row else { return }
                    cursor = row
                    // ponytail: the lazy stack guesses the height of rows it hasn't drawn (threads, drafts), so jump,
                    // let it lay them out and jump again. Doing better needs scroll-offset tracking.
                    proxy.scrollTo(row, anchor: .top)
                    for _ in 0..<2 {
                        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                        proxy.scrollTo(row, anchor: .top)
                    }
                }
                }
            } else {
                ContentUnavailableView("No diff available", systemImage: "doc.questionmark",
                                       description: Text("GitHub doesn't provide a diff for binary or very large files."))
            }
        }
        .onDisappear {
            // Moving to another file (⌘[ / ⌘], the tree) or tab keeps an unsent comment as a local draft.
            if let composing, !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = model.addDraft(pr, anchor: composing, body: draftText)
            }
        }
    }

    /// The rendered diff, once it matches the current patch and layout. Colors don't invalidate it: the old ones
    /// show until `onChange` renders again.
    private var currentDiff: RenderedDiff? {
        rendered?.key.patch == file.patch && rendered?.key.mode == mode ? rendered : nil
    }

    /// The diff row of each key area, index-aligned with `keyAreas`; nil for whole-file areas and lines not in the diff.
    private var areaRows: [Int?] {
        guard let diff = currentDiff else { return [] }
        return keyAreas.map { area in area.lines.flatMap { diff.index.row(ofNewLines: $0) } }
    }

    /// Diff rows with shown threads (Involving Me hides the others) or drafts, and the anchors on each (a split row
    /// can have one per side).
    private func commentRows(_ shownThreads: [ReviewThread]) -> [Int: [ReviewDeskCore.Anchor]] {
        guard let diff = currentDiff else { return [:] }
        let anchors = Set(shownThreads.compactMap { thread in thread.line.map { ReviewDeskCore.Anchor(path: file.filename, line: $0, side: thread.side) } })
            .union(drafts.map(\.anchor))
        return Dictionary(grouping: anchors.compactMap { anchor in diff.row(for: anchor).map { ($0, anchor) } }, by: \.0).mapValues { $0.map(\.1) }
    }

    private var allThreads: [ReviewThread] {
        model.details[pr.id]?.threads.filter { thread in
            thread.path == file.filename
                && commitView.map { view in thread.line.map { view.shows(ReviewDeskCore.Anchor(path: file.filename, line: $0, side: thread.side)) } ?? false } != false
        } ?? []
    }

    /// The file's drafts, those that sit on a line of this view.
    private var drafts: [Draft] {
        model.drafts(for: pr.id).filter { $0.anchor.path == file.filename && commitView?.shows($0.anchor) != false }
    }

    /// The threads shown: with Involving Me on, only those involving the viewer (the gutter still marks the others).
    private var threads: [ReviewThread] { allThreads.filter { !involvedOnly || $0.involves(model.viewer) } }

    private var hiddenIDs: Set<String> { Set(model.drafts(for: pr.id).compactMap(\.remoteID)) }

    /// Lines with threads or drafts, worked out once per redraw instead of once per row.
    private var commentedAnchors: Set<ReviewDeskCore.Anchor> {
        Set(allThreads.compactMap { thread in thread.line.map { ReviewDeskCore.Anchor(path: file.filename, line: $0, side: thread.side) } })
            .union(drafts.map(\.anchor))
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
                            .overlay(alignment: .leading) { keyMark(row.right) }
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
                            .overlay(alignment: .leading) { keyMark(line) }
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

    /// Marks lines inside the AI's key areas, dimmed when they come from an older head; the one picked in the file
    /// list gets a wider bar and a tint.
    @ViewBuilder
    private func keyMark(_ line: DiffLine?) -> some View {
        if let line, line.kind != .removed, let number = line.newLine {
            if selectedArea?.contains(line: number) == true {
                DiffColors.keyArea.opacity(0.15).allowsHitTesting(false)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.orange).frame(width: 5).help("The key area selected in the file list")
                    }
            } else if keyAreas.contains(where: { $0.contains(line: number) }) {
                Rectangle().fill(DiffColors.keyArea.opacity(keyAreasOutdated ? 0.35 : 1)).frame(width: 3)
                    .help(keyAreasOutdated ? "Key area from an analysis of an older commit: the lines may have moved since"
                                           : "Key area: read this before submitting")
            }
        }
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
            } else if let anchor, hovered, commitView?.accepts(anchor) == false {
                Image(systemName: "plus.square").foregroundStyle(DiffColors.lineNumber)
                    .help("GitHub takes comments only on lines of the whole pull request's diff. To comment here, pick All commits or a range that ends at the latest commit.")
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
            ForEach(drafts.filter { $0.anchor == anchor }) {
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
    /// The widest line in points, with the diff's font.
    var widest: CGFloat
    /// Rows by new-side line and by comment anchor, matching the ForEach ids of `mode`.
    var index: DiffIndex

    @MainActor init(_ key: Key, path: String) {
        let lines = Diff.parse(key.patch)
        let syntax = Syntax.language(for: path).map { Syntax.tokens(diff: lines, language: $0) } ?? [:]
        var text: [DiffLine: AttributedString] = [:]
        for line in lines where line.kind != .hunk {
            text[line] = FileDiffView.highlighted(line.text, tokens: syntax[line] ?? [])
        }
        (self.key, self.lines, self.text) = (key, lines, text)
        changes = Diff.changes(lines)
        widest = Self.widest(lines.map(\.text))
        rows = key.mode == .split ? Diff.sideBySide(lines) : []
        index = key.mode == .split ? DiffIndex(rows: rows, path: path) : DiffIndex(lines: lines, path: path)
    }

    /// A character is one to 2.5 columns wide (CJK about 1.6, emoji 2.3, a tab up to 4), so only the lines that
    /// could be the widest are measured, not every line of a big file.
    static func widest(_ texts: [String]) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let column = ("M" as NSString).size(withAttributes: [.font: font]).width
        let tabs = texts.map { text in text.count { $0 == "\t" } }
        let atLeast = zip(texts, tabs).map { CGFloat($0.count - $1) * column }.max() ?? 0
        return zip(texts, tabs).filter { CGFloat($0.count + $1 * 3) * 2.5 * column >= atLeast }
            .map { NSAttributedString(string: $0.0, attributes: [.font: font]).size().width }.max() ?? 0
    }

    /// Offset of the target's first diff row, matching the ForEach ids; nil when its new-side lines aren't in the diff.
    /// An old-file target (a thread on a removed line) lands on the first row at or after its line.
    func row(for target: LineTarget) -> Int? {
        switch (mode, target.side) {
        case (_, .right): index.row(ofNewLines: target.line...max(target.line, target.endLine ?? target.line))
        // ponytail: scans; only a click on a removed-line thread in Conversation gets here.
        case (.unified, .left): lines.firstIndex { $0.kind != .added && ($0.oldLine ?? 0) >= target.line }
        case (.split, .left): rows.firstIndex { ($0.left?.oldLine ?? 0) >= target.line }
        }
    }

    /// Offset of the row a comment is anchored to.
    func row(for anchor: ReviewDeskCore.Anchor) -> Int? {
        index.row(of: anchor)
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
    /// the diff pane's frame in the window, and how many code columns share it with the gutter.
    @ObservationIgnored var codeWidth: CGFloat = 0 { didSet { clamp() } }
    @ObservationIgnored var frame: CGRect = .zero { didSet { clamp() } }
    @ObservationIgnored var columns: CGFloat = 1 { didSet { clamp() } }
    private let gutter: CGFloat

    init(gutter: CGFloat) { self.gutter = gutter }

    /// How far the widest line reaches past its code column.
    var limit: CGFloat { max(0, codeWidth - (frame.width - gutter) / columns) }

    private func clamp() { if x > limit { x = limit } }
    @ObservationIgnored private var monitor: Any?
    /// Whether the current trackpad gesture scrolls sideways, decided by its first movement: a mostly vertical
    /// swipe never drifts sideways, and a diagonal one doesn't flip between the two.
    @ObservationIgnored private var sideways: Bool?

    // ponytail: trackpad and (shift-)wheel only, no visible scroller, and dragging a selection past the edge
    // doesn't scroll; add an NSScroller if people miss it. The event is passed on, so a horizontally scrolling
    // code block inside an inline comment under the pointer scrolls with the diff.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let (dx, dy, precise) = (event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
            let (phase, momentum, window, location) = (event.phase, event.momentumPhase, event.window, event.locationInWindow)
            MainActor.assumeIsolated {
                guard let self, self.contains(location, in: window) else { return }
                if phase.contains(.began) || phase.contains(.mayBegin) { self.sideways = nil }
                // A mouse wheel has no phases: each of its events decides alone.
                let inGesture = !phase.isEmpty || !momentum.isEmpty
                if !inGesture || self.sideways == nil, dx != 0 || dy != 0 { self.sideways = abs(dx) > abs(dy) }
                guard self.sideways == true else { return }
                self.x = min(max(0, self.x - (precise ? dx : dx * Self.charWidth * 3)), self.limit)
            }
            return event
        }
    }

    /// The pointer is over the diff: checked against its frame rather than hover, which isn't reported when the diff
    /// appears under a still pointer. Popovers and sheets over the diff are windows that can't be main, so they're skipped.
    private func contains(_ location: NSPoint, in eventWindow: NSWindow?) -> Bool {
        // Events posted by other tools come without a window, located on screen: take the frontmost window there.
        guard let window = eventWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.frame.contains(location) }),
              window.canBecomeMain, let content = window.contentView else { return false }
        let inWindow = eventWindow == nil ? window.convertPoint(fromScreen: location) : location
        let point = content.convert(inWindow, from: nil) // SwiftUI's global space is the content view's, top-left origin
        return frame.contains(CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y))
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

/// A scroll to a diff row; a fresh id lets the same row be revisited.
private struct Jump: Equatable {
    var row: Int
    var id = UUID()
}

/// Two values as one `task(id:)`.
private struct Pair<A: Equatable, B: Equatable>: Equatable {
    var a: A
    var b: B
    init(_ a: A, _ b: B) { (self.a, self.b) = (a, b) }
}
