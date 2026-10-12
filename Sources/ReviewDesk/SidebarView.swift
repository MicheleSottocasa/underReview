import ReviewDeskCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var addingPR = false
    @ViewState private var renaming: Folder?
    @ViewState private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Label("Inbox", systemImage: "tray")
                .badge(model.items(for: .inbox).count)
                .tag(SidebarSelection.inbox)
                .dropDestination(for: String.self) { keys, _ in drop(keys, into: nil) }
            Label("All Pull Requests", systemImage: "list.bullet").tag(SidebarSelection.all)

            Section("Projects") {
                OutlineGroup(FolderNode.tree(model.org, parent: nil), children: \.children) { node in
                    Label(node.folder.name, systemImage: node.folder.parentID == nil ? "folder.fill" : "folder")
                        .badge(model.items(for: .folder(node.id)).count)
                        .tag(SidebarSelection.folder(node.id))
                        .dropDestination(for: String.self) { keys, _ in drop(keys, into: node.id) }
                        .contextMenu {
                            Button("New Folder Inside") { model.org.addFolder("New Folder", in: node.id) }
                            Button("Rename…") {
                                newName = node.folder.name
                                renaming = node.folder
                            }
                            Divider()
                            Button("Delete", role: .destructive) { model.deleteFolder(node.id) }
                        }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .toolbar {
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
    }

    /// Folders only change where items appear; stacks and GitHub state are untouched.
    private func drop(_ keys: [String], into folder: UUID?) -> Bool {
        for key in keys { model.move(key, to: folder) }
        return !keys.isEmpty
    }
}

struct FolderNode: Identifiable {
    var folder: Folder
    var children: [FolderNode]?

    var id: UUID { folder.id }

    static func tree(_ org: Organization, parent: UUID?) -> [FolderNode] {
        org.children(of: parent).map { folder in
            let children = tree(org, parent: folder.id)
            return FolderNode(folder: folder, children: children.isEmpty ? nil : children)
        }
    }

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
