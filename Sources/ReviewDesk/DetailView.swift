import ReviewDeskCore
import SwiftUI

enum DetailTab: String, CaseIterable {
    case conversation = "Conversation", changes = "Changes", ai = "AI Review", notes = "Notes"
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    @ViewState private var tab = DetailTab.conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding()
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            Divider().padding(.top, 8)
            switch tab {
            case .conversation: ConversationView(pr: pr, detail: model.details[pr.id])
            case .changes: ChangesView(pr: pr)
            case .ai: AIView(pr: pr)
            case .notes: NotesView(pr: pr)
            }
        }
        // Changes takes the whole window, like a diff editor; only restore a sidebar the app hid itself.
        .onChange(of: tab, initial: true) { _, tab in
            if tab == .changes, model.columns != .detailOnly {
                model.columns = .detailOnly
                model.sidebarAutoHidden = true
            } else if tab != .changes, model.sidebarAutoHidden {
                model.columns = .all
                model.sidebarAutoHidden = false
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(pr.title).font(.title2.bold()).textSelection(.enabled)
                Spacer()
                Button("Open on GitHub") { model.openOnGitHub(pr) }
            }
            HStack(spacing: 8) {
                StateBadge(pr: pr)
                Text(verbatim: "\(pr.repo)#\(pr.number) by \(pr.author)")
                Text("\(pr.headRefName) → \(pr.baseRefName)").font(.caption.monospaced())
                if let position = pr.stackPosition, let stack = pr.stack {
                    Text(verbatim: "Stack #\(stack.number): \(position) of \(stack.entries.count)")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

struct NotesView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        Form {
            Section("Private note on this pull request") { editor(key: "pr:\(pr.id)") }
            if pr.stack != nil {
                Section("Private note on the whole stack") { editor(key: pr.itemKey) }
            }
            Text("Notes stay on this Mac and are never sent to GitHub.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func editor(key: String) -> some View {
        TextEditor(text: Binding(
            get: { model.org.notes[key] ?? "" },
            set: { model.org.notes[key] = $0.isEmpty ? nil : $0 }
        ))
        .font(.body)
        .frame(minHeight: 120)
    }
}
