import ReviewDeskCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var addingPR = false

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Label("Inbox", systemImage: "tray").badge(model.items(for: .inbox).count).tag(SidebarSelection.inbox)
            Label("All Pull Requests", systemImage: "list.bullet").tag(SidebarSelection.all)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .toolbar {
            ToolbarItem {
                Button { addingPR = true } label: { Label("Add Pull Request", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $addingPR) { AddPRSheet() }
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
