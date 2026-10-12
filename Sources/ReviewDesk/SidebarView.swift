import ReviewDeskCore
import SwiftUI

/// One outline: Inbox (unfiled) and Projects, with PRs and stacks inside. Cmd/Shift-click selects several;
/// right-click acts on the whole selection.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var addingPR = false
    @ViewState private var renaming: Folder?
    @ViewState private var newName = ""
    @ViewState private var confirmingStop: Set<String>?

    var body: some View {
        @Bindable var model = model
        let index = model.itemIndex()
        List(selection: $model.selection) {
            DisclosureGroup(isExpanded: model.expansion("inbox")) {
                RepoGroups(items: index[nil] ?? [], scope: "inbox", folder: nil)
            } label: {
                Label("Inbox", systemImage: "tray")
                    .badge(openCount(index[nil] ?? []))
                    .dropDestination(for: String.self) { payload, _ in drop(payload, into: nil) }
            }

            Section("Projects") {
                ForEach(model.org.children(of: nil)) { FolderBranch(folder: $0, index: index) }
                if model.org.folders.isEmpty {
                    Button("New Project") { model.org.addFolder("New Project") }.buttonStyle(.link)
                }
            }
        }
        .searchable(text: $model.filter, placement: .sidebar, prompt: "Filter")
        .contextMenu(forSelectionType: SidebarID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            for case .folder(let id) in ids { model.toggleExpansion("folder:\(id)") }
        }
        .onDeleteCommand {
            let keys = model.itemKeys(model.selection)
            if !keys.isEmpty { confirmingStop = keys }
        }
        .overlay {
            if model.prs.isEmpty && !model.isRefreshing {
                ContentUnavailableView {
                    Label("No pull requests", systemImage: "arrow.triangle.pull")
                } actions: {
                    Button("Add Pull Request…") { addingPR = true }
                }
            } else if !model.filter.isEmpty && index.isEmpty {
                ContentUnavailableView.search(text: model.filter)
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(PRStateFilter.allCases, id: \.self) { state in
                        Toggle(state.title, isOn: Binding(
                            get: { model.stateFilter.contains(state) },
                            set: { if $0 { model.stateFilter.insert(state) } else { model.stateFilter.remove(state) } }
                        ))
                    }
                    Divider()
                    Button("Show All") { model.stateFilter = Set(PRStateFilter.allCases) }
                } label: {
                    Label("Filter", systemImage: model.isFilteringState ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help("Show pull requests by state")
            }
            ToolbarItem {
                Menu {
                    Button("Add Pull Request…") { addingPR = true }
                    Button("New Project") { model.org.addFolder("New Project") }
                } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $addingPR) { AddPRSheet() }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let folder = renaming, !newName.isEmpty { model.org.renameFolder(folder.id, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(stopTitle, isPresented: Binding(get: { confirmingStop != nil }, set: { if !$0 { confirmingStop = nil } })) {
            Button(stopTitle, role: .destructive) {
                if let keys = confirmingStop { model.stopMonitoring(keys) }
            }
        } message: {
            Text("They disappear from ReviewDesk and stop notifying you. Adding one again by URL brings it back.")
        }
    }

    private var stopTitle: String {
        let count = confirmingStop?.count ?? 0
        return count == 1 ? "Stop Monitoring" : "Stop Monitoring \(count) Items"
    }

    @ViewBuilder
    private func menu(for ids: Set<SidebarID>) -> some View {
        let keys = model.itemKeys(ids)
        let folders = ids.compactMap { if case .folder(let id) = $0 { id } else { nil } }
        if ids.isEmpty {
            Button("Add Pull Request…") { addingPR = true }
            Button("New Project") { model.org.addFolder("New Project") }
        } else if keys.isEmpty, folders.count == 1, let folder = model.org.folders.first(where: { $0.id == folders[0] }) {
            Button("New Folder Inside") { model.org.addFolder("New Folder", in: folder.id) }
            Button("Rename…") {
                newName = folder.name
                renaming = folder
            }
            Divider()
            Button("Delete Folder", role: .destructive) { model.deleteFolder(folder.id) }
        } else if !keys.isEmpty {
            let label = keys.count == 1 ? "" : " \(keys.count) Items"
            Menu("Move\(label) To") {
                Button("Inbox") { model.move(keys, to: nil) }
                Divider()
                ForEach(FolderNode.flat(model.org), id: \.folder.id) { entry in
                    Button(String(repeating: "    ", count: entry.depth) + entry.folder.name) { model.move(keys, to: entry.folder.id) }
                }
            }
            let muted = keys.allSatisfy(model.org.muted.contains)
            Button(muted ? "Unmute Notifications" : "Mute Notifications") { model.setMuted(keys, !muted) }
            Button("Open on GitHub") { model.openOnGitHub(ids) }
            Divider()
            Button("Stop Monitoring\(label)…", role: .destructive) { confirmingStop = keys }
        }
    }

    private func drop(_ payload: [String], into folder: UUID?) -> Bool {
        let keys = Set(payload.flatMap { $0.split(separator: "\n").map(String.init) })
        model.move(keys, to: folder)
        return !keys.isEmpty
    }

    private func openCount(_ items: [Item]) -> Int {
        items.reduce(0) { $0 + $1.pullRequests.filter { $0.state == "OPEN" }.count }
    }
}

/// A project or folder: subfolders first, then its items.
struct FolderBranch: View {
    @Environment(AppModel.self) private var model
    let folder: Folder
    let index: [UUID?: [Item]]

    var body: some View {
        let children = model.org.children(of: folder.id)
        let items = index[folder.id] ?? []
        if model.filter.isEmpty || subtreeCount(folder.id) > 0 {
            DisclosureGroup(isExpanded: model.expansion("folder:\(folder.id)")) {
                ForEach(children) { FolderBranch(folder: $0, index: index) }
                RepoGroups(items: items, scope: "folder:\(folder.id)", folder: folder.id)
                if children.isEmpty && items.isEmpty {
                    Text("Drop pull requests here").font(.callout).foregroundStyle(.tertiary)
                }
            } label: {
                Label(folder.name, systemImage: folder.parentID == nil ? "folder.fill" : "folder")
                    .badge(openCount(folder.id))
                    .tag(SidebarID.folder(folder.id))
                    .dropDestination(for: String.self) { payload, _ in
                        let keys = Set(payload.flatMap { $0.split(separator: "\n").map(String.init) })
                        model.move(keys, to: folder.id)
                        return !keys.isEmpty
                    }
            }
        }
    }

    private func subtreeCount(_ id: UUID) -> Int {
        (index[id]?.count ?? 0) + model.org.children(of: id).reduce(0) { $0 + subtreeCount($1.id) }
    }

    /// Open PRs in this folder and its subfolders.
    private func openCount(_ id: UUID) -> Int {
        (index[id] ?? []).reduce(0) { $0 + $1.pullRequests.filter { $0.state == "OPEN" }.count }
            + model.org.children(of: id).reduce(0) { $0 + openCount($1.id) }
    }
}

/// Items of one place (Inbox or a folder) split into collapsible per-repo groups.
struct RepoGroups: View {
    @Environment(AppModel.self) private var model
    let items: [Item]
    let scope: String
    let folder: UUID?

    var body: some View {
        ForEach(Dictionary(grouping: items, by: \.repo).sorted { $0.key < $1.key }, id: \.key) { repo, group in
            DisclosureGroup(isExpanded: model.expansion("repo:\(scope):\(repo)")) {
                ItemRows(items: group)
            } label: {
                Label(String(repo.split(separator: "/").last ?? ""), systemImage: "shippingbox")
                    .foregroundStyle(.secondary)
                    .badge(group.reduce(0) { $0 + $1.pullRequests.count })
                    .help(repo)
                    .dropDestination(for: String.self) { payload, _ in
                        let keys = Set(payload.flatMap { $0.split(separator: "\n").map(String.init) })
                        model.move(keys, to: folder)
                        return !keys.isEmpty
                    }
            }
        }
    }
}

struct ItemRows: View {
    @Environment(AppModel.self) private var model
    let items: [Item]

    var body: some View {
        ForEach(items) { item in
            if item.isStack {
                StackGroup(item: item)
            } else if let pr = item.pullRequests.first {
                PRRow(pr: pr, muted: model.org.muted.contains(item.key), requested: pr.requestedReviewers.contains(model.viewer),
                      review: model.reviewStatus(pr))
                    .tag(SidebarID.pr(pr.id))
                    .draggable(model.dragPayload(item.key))
            }
        }
    }
}

/// A native stack: clicking its title collapses or expands it; children run from the top of the stack down.
struct StackGroup: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        DisclosureGroup(isExpanded: model.expansion(item.key)) {
            ForEach(item.pullRequests.reversed()) { pr in
                StackChildRow(pr: pr, review: model.reviewStatus(pr))
                    .tag(SidebarID.pr(pr.id))
                    .draggable(model.dragPayload(item.key))
            }
        } label: {
            StackHeader(item: item, muted: model.org.muted.contains(item.key), review: item.pullRequests.map(model.reviewStatus).reduce(ReviewStatus(), +))
                .tag(SidebarID.stack(item.key))
                .draggable(model.dragPayload(item.key))
                .simultaneousGesture(TapGesture().onEnded {
                    // Plain click toggles; Cmd/Shift-click only changes the selection.
                    if NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) { model.toggleExpansion(item.key) }
                })
        }
    }
}

// MARK: - Rows

struct StateIcon: View {
    let pr: PullRequest

    var body: some View {
        let (symbol, color): (String, Color) = switch pr.state {
        case "MERGED": ("arrow.triangle.merge", .purple)
        case "CLOSED": ("xmark.circle", .red)
        default: ("arrow.triangle.pull", pr.isDraft ? .secondary : .green)
        }
        Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
    }
}

/// Standalone PR: state icon and title, then `#n · author · age` (the repo is the group above).
struct PRRow: View {
    let pr: PullRequest
    var muted = false
    var requested = false
    var review = ReviewStatus()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StateIcon(pr: pr)
            VStack(alignment: .leading, spacing: 1) {
                Text(pr.title).lineLimit(1).truncationMode(.tail)
                Text(verbatim: "#\(pr.number) · \(pr.author) · \(age(pr.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ReviewIndicator(status: review)
            Indicators(muted: muted, requested: requested)
        }
        .help(Text(verbatim: "\(pr.repo)#\(pr.number) · \(pr.headRefName) → \(pr.baseRefName)"))
    }
}

struct StackHeader: View {
    let item: Item
    var muted = false
    var review = ReviewStatus()

    var body: some View {
        let open = item.pullRequests.filter { $0.state == "OPEN" }.count
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "square.stack.3d.up").foregroundStyle(.blue).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.pullRequests.first?.title ?? "Stack").lineLimit(1)
                Text(verbatim: "\(item.pullRequests.count) PRs · \(open) open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            ReviewIndicator(status: review)
            Indicators(muted: muted, requested: false)
        }
    }
}

/// Compact: repo and author are the same across a stack, so they live in the tooltip.
struct StackChildRow: View {
    let pr: PullRequest
    var review = ReviewStatus()

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(pr.stackPosition ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
            StateIcon(pr: pr)
            Text(pr.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            ReviewIndicator(status: review)
        }
        .help(Text(verbatim: "\(pr.repo)#\(pr.number) by \(pr.author)"))
    }
}

/// Comments to send (orange), my submitted review (green/red/blue), replies I owe (purple). Nothing when not started.
struct ReviewIndicator: View {
    let status: ReviewStatus

    var body: some View {
        HStack(spacing: 6) {
            if status.hasPendingReview {
                Label(status.toSend > 0 ? "\(status.toSend)" : "", systemImage: "paperplane.fill")
                    .foregroundStyle(.orange)
                    .help(status.toSend == 1 ? "1 review comment not sent yet" : "\(status.toSend) review comments not sent yet")
            } else if let submitted = status.submitted, let (symbol, color, text) = Self.submitted(submitted) {
                Image(systemName: symbol).foregroundStyle(color).help(text)
            }
            if status.awaitingReply > 0 {
                Label("\(status.awaitingReply)", systemImage: "arrowshape.turn.up.left.fill")
                    .foregroundStyle(.purple)
                    .help(status.awaitingReply == 1 ? "1 conversation waiting for your reply" : "\(status.awaitingReply) conversations waiting for your reply")
            }
        }
        .labelStyle(CompactLabel())
        .font(.caption)
    }

    static func submitted(_ state: String) -> (String, Color, String)? {
        switch state {
        case "APPROVED": ("checkmark.circle.fill", .green, "You approved; all your comments are sent")
        case "CHANGES_REQUESTED": ("exclamationmark.circle.fill", .red, "You requested changes; all your comments are sent")
        case "COMMENTED": ("text.bubble.fill", .blue, "You reviewed; all your comments are sent")
        default: nil
        }
    }
}

/// Icon then a tight count, without the default label spacing.
private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title.monospacedDigit()
        }
    }
}

struct Indicators: View {
    let muted: Bool
    let requested: Bool

    var body: some View {
        HStack(spacing: 4) {
            if requested { Image(systemName: "eye").help("Your review is requested") }
            if muted { Image(systemName: "bell.slash").help("Notifications muted") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct StateBadge: View {
    let pr: PullRequest

    var body: some View {
        let (text, color): (String, Color) = switch pr.state {
        case "MERGED": ("Merged", .purple)
        case "CLOSED": ("Closed", .red)
        default: pr.isDraft ? ("Draft", .gray) : ("Open", .green)
        }
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

private func age(_ date: Date) -> String {
    date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
}

struct FolderNode {
    /// Flattened with depth, for "Move to" menus.
    static func flat(_ org: Organization, parent: UUID? = nil, depth: Int = 0) -> [(folder: Folder, depth: Int)] {
        org.children(of: parent).flatMap { [($0, depth)] + flat(org, parent: $0.id, depth: depth + 1) }
    }
}

struct AddPRSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var link = ""
    @ViewState private var error: String?
    @ViewState private var working = false

    var body: some View {
        Form {
            TextField("Pull request", text: $link, prompt: Text("https://github.com/owner/repo/pull/123"))
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    working = true
                    Task {
                        do {
                            try await model.addPR(link)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        working = false
                    }
                }
                .disabled(link.isEmpty || working)
            }
        }
    }
}
