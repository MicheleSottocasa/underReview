import AppKit
import ReviewDeskCore
import SwiftUI

/// Checks the PR out in the repo's local clone; the menu links or changes the clone.
struct CheckOutButton: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    /// PR id → the branch its checkout ended on; keyed so a checkout finishing after a switch shows on its own PR.
    @ViewState private var checkedOut: [String: String] = [:]

    var body: some View {
        let path = model.localClones[pr.repo]
        let working = path.map(model.checkingOut.contains) ?? false
        HStack(spacing: 8) {
            if let checkedOut = checkedOut[pr.id] {
                Label(checkedOut, systemImage: "checkmark.circle")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .help("Checked out in \(path ?? "the local clone")")
            }
            Menu(working ? "Checking Out…" : "Check Out") {
                Button(path == nil ? "Link Local Clone…" : "Change Local Clone…") {
                    Task { await model.chooseClone(for: pr.repo) }
                }
                if let path {
                    Button("Show Clone in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            } primaryAction: {
                Task { checkedOut[pr.id] = await model.checkOut(pr) }
            }
            .fixedSize()
            .disabled(working)
            .help(path.map { "Check out \(pr.headRefName) in \($0) with gh pr checkout" }
                ?? "Link the local clone of \(pr.repo), then check out \(pr.headRefName) there")
        }
    }
}

/// Settings › Repositories: the local clone of each repo.
struct CloneSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.knownRepos.isEmpty {
                    Text("Repositories show up here once their pull requests are listed.").foregroundStyle(.secondary)
                }
                ForEach(model.knownRepos, id: \.self) { repo in
                    LabeledContent(repo) {
                        HStack(spacing: 6) {
                            Text(model.localClones[repo].map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not linked")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Button(model.localClones[repo] == nil ? "Link…" : "Change…") {
                                Task { await model.chooseClone(for: repo) }
                            }
                            if model.localClones[repo] != nil {
                                Button("Unlink") { model.localClones[repo] = nil }
                            }
                        }
                    }
                }
            } header: {
                Text("Local clones")
            } footer: {
                Text("Check Out runs gh pr checkout in the clone. It refuses when it could lose or mix up work: uncommitted changes, an unfinished merge, rebase or bisect, detached commits, or untracked and ignored files the pull request would overwrite.")
            }
        }
        .formStyle(.grouped)
    }
}
