import AppKit
import ReviewDeskCore
import SwiftUI

extension AppModel {
    /// Items per folder (nil = Inbox), filtered by the sidebar search. Build once per render.
    func itemIndex() -> [UUID?: [Item]] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let items = allItems.filter { item in
            query.isEmpty || item.pullRequests.contains { pr in
                [pr.title, "#\(pr.number)", pr.author, pr.repo, pr.headRefName].contains { $0.lowercased().contains(query) }
            }
        }
        return Dictionary(grouping: items) { org.placements[$0.key] }
    }

    func isExpanded(_ key: String) -> Bool {
        if !filter.isEmpty { return true }
        let openByDefault = !key.hasPrefix("stack:")
        return openByDefault != toggledExpansion.contains(key)
    }

    func expansion(_ key: String) -> Binding<Bool> {
        Binding(get: { self.isExpanded(key) }, set: { if $0 != self.isExpanded(key) { self.toggleExpansion(key) } })
    }

    func toggleExpansion(_ key: String) {
        if toggledExpansion.contains(key) { toggledExpansion.remove(key) } else { toggledExpansion.insert(key) }
    }

    /// Expands the PR's folder chain and stack so it's visible in the sidebar.
    func reveal(_ pr: PullRequest) {
        var folder = org.placements[pr.itemKey]
        while let id = folder {
            if !isExpanded("folder:\(id)") { toggleExpansion("folder:\(id)") }
            folder = org.folders.first { $0.id == id }?.parentID
        }
        if org.placements[pr.itemKey] == nil, !isExpanded("inbox") { toggleExpansion("inbox") }
        if pr.stack != nil, !isExpanded(pr.itemKey) { toggleExpansion(pr.itemKey) }
    }

    // MARK: Bulk actions on a selection

    /// Placement keys for the selected rows: a PR inside a stack maps to its stack.
    func itemKeys(_ ids: Set<SidebarID>) -> Set<String> {
        Set(ids.compactMap { id in
            switch id {
            case .folder: nil
            case .stack(let key): key
            case .pr(let prID): prs[prID]?.itemKey
            }
        })
    }

    /// Dragging a selected row carries the whole selection.
    func dragPayload(_ key: String) -> String {
        let keys = itemKeys(selection)
        return (keys.contains(key) ? keys : [key]).sorted().joined(separator: "\n")
    }

    func move(_ keys: Set<String>, to folder: UUID?) {
        var updated = org
        for key in keys { updated.place(key, in: folder) }
        org = updated
    }

    func setMuted(_ keys: Set<String>, _ muted: Bool) {
        if muted { org.muted.formUnion(keys) } else { org.muted.subtract(keys) }
    }

    func openOnGitHub(_ ids: Set<SidebarID>) {
        for id in ids {
            switch id {
            case .pr(let prID): prs[prID].map(openOnGitHub)
            case .stack(let key): allItems.first { $0.key == key }?.pullRequests.last.map(openOnGitHub)
            case .folder: break
            }
        }
    }

    func stopMonitoring(_ keys: Set<String>) {
        var updated = org
        for pr in prs.values where keys.contains(pr.itemKey) {
            updated.unfollow(id: pr.id)
            prs[pr.id] = nil
            if pr.id == selectedPRID { selectedPRID = nil }
        }
        org = updated
        selection = []
    }
}
