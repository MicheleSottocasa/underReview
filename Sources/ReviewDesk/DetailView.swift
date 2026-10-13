import ReviewDeskCore
import SwiftUI

enum DetailTab: String, CaseIterable {
    case conversation = "Conversation", followUp = "Follow-up", risk = "Risk", changes = "Changes", ai = "AI Review", notes = "Notes"
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        @Bindable var model = model
        // Follow-up only shows when there's something to check or a past check to read.
        let tabs = DetailTab.allCases.filter { $0 != .followUp || model.showsFollowUp(pr) }
        let tab = tabs.contains(model.detailTab) ? model.detailTab : .conversation
        VStack(alignment: .leading, spacing: 0) {
            if pr.isDemo {
                Label("Demo pull request for the tour: fictional, read-only, never saved or sent anywhere.", systemImage: "graduationcap")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(Color.purple.opacity(0.1))
            }
            header.padding().tourAnchor([.header], edge: .bottom)
            if model.isFollowUpDue(pr), tab != .followUp, model.followUpRuns(for: pr.id).first?.headRefOid != pr.headRefOid {
                FollowUpNotice(pr: pr).padding(.horizontal).padding(.bottom, 8)
            }
            Picker("", selection: Binding(get: { tab }, set: { model.detailTab = $0 })) {
                ForEach(tabs, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .tourAnchor([.conversation, .risk, .changes, .ai, .notes, .settings], edge: .bottom)
            Divider().padding(.top, 8)
            switch tab {
            case .conversation: ConversationView(pr: pr, detail: model.details[pr.id])
            case .followUp: FollowUpView(pr: pr)
            case .risk: RiskView(pr: pr)
            case .changes: ChangesView(pr: pr)
            case .ai: AIView(pr: pr)
            case .notes: NotesView(pr: pr)
            }
        }
        .modifier(LinkHandler(pr: pr))
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
                MergeBadges(pr: pr)
                if model.hasOutdatedAnalysis(pr) {
                    Button { model.detailTab = .ai } label: { Badge(text: "AI analysis outdated", color: .orange) }
                        .buttonStyle(.plain)
                        .help("The author pushed after the latest AI analysis. Open AI Review to run it again.")
                }
                Text(verbatim: "\(pr.repo)#\(pr.number) by \(pr.author)")
                Text("\(pr.headRefName) → \(pr.baseRefName)").font(.caption.monospaced())
                if let head = URL(string: "https://github.com/\(pr.repo)/commit/\(pr.headRefOid)") {
                    Link(String(pr.headRefOid.prefix(7)), destination: head).font(.caption.monospaced()).foregroundStyle(.tint).help("The head commit, on GitHub")
                }
                if let position = pr.stackPosition, let stack = pr.stack {
                    Text(verbatim: "Stack #\(stack.number): \(position) of \(stack.entries.count)")
                }
                if pr.changedFiles > 0 {
                    HStack(spacing: 4) {
                        Text("+\(pr.additions)").foregroundStyle(.green)
                        Text("−\(pr.deletions)").foregroundStyle(.red)
                    }
                    .monospacedDigit()
                    .help("\(pr.additions) lines added and \(pr.deletions) removed in \(pr.changedFiles) file\(pr.changedFiles == 1 ? "" : "s")")
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

/// *Conflicts* (opens GitHub's conflict page) and *Behind <base>* (opens the PR, where it can be updated).
/// Nothing while GitHub is still computing mergeability.
struct MergeBadges: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        if pr.hasConflicts {
            badge("Conflicts", color: .red) { model.openConflicts(pr) }
                .help("Has conflicts with \(pr.baseRefName). Click to resolve them on GitHub.")
        }
        if pr.isBehind {
            badge("Behind \(pr.baseRefName)", color: .orange) { model.openOnGitHub(pr) }
                .help("\(pr.baseRefName) has commits this branch doesn't have yet. Click to update it on GitHub.")
        }
    }

    private func badge(_ text: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) { Image(systemName: "exclamationmark.triangle.fill"); Text(text) }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }
}
