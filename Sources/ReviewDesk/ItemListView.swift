import ReviewDeskCore
import SwiftUI

struct ItemListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.items(for: model.sidebar)
        List(selection: $model.selectedPRID) {
            ForEach(items) { item in
                if item.isStack {
                    Section {
                        ForEach(item.pullRequests.reversed()) { pr in row(pr, item: item) }
                    } header: {
                        Label("Stack · \(item.pullRequests.first?.repo ?? "") · \(item.pullRequests.count) PRs", systemImage: "square.3.layers.3d")
                            .draggable(item.key)
                            .contextMenu { ItemMenu(item: item) }
                    }
                } else if let pr = item.pullRequests.first {
                    row(pr, item: item)
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(model.isRefreshing ? "Loading…" : "Nothing here", systemImage: "tray")
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        .onChange(of: model.selectedPRID) { _, id in
            if let id { Task { await model.loadDetail(id) } }
        }
    }

    private func row(_ pr: PullRequest, item: Item) -> some View {
        PRRow(pr: pr)
            .tag(pr.id)
            .draggable(item.key) // dragging any PR of a stack moves the whole stack
            .contextMenu { ItemMenu(item: item) }
    }
}

struct PRRow: View {
    let pr: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let position = pr.stackPosition { Text("\(position)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Text(pr.title).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text("\(pr.repo)#\(pr.number)")
                Text(pr.author)
                StateBadge(pr: pr)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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

struct ItemMenu: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        if let pr = item.pullRequests.first {
            Button("Open on GitHub") { model.openOnGitHub(pr) }
        }
        Menu(item.isStack ? "Move Stack To" : "Move To") {
            Button("Inbox (unfiled)") { model.move(item.key, to: nil) }
            Divider()
            ForEach(FolderNode.flat(model.org), id: \.folder.id) { entry in
                Button(String(repeating: "    ", count: entry.depth) + entry.folder.name) { model.move(item.key, to: entry.folder.id) }
            }
        }
        Divider()
        Button(item.isStack ? "Stop Monitoring Stack" : "Stop Monitoring", role: .destructive) { model.stopMonitoring(item) }
    }
}
