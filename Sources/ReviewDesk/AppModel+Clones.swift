import AppKit
import ReviewDeskCore

extension AppModel {
    /// Asks for the clone of `repo` and links it once one of its remotes is on that repo. Returns whether it linked.
    @discardableResult
    func chooseClone(for repo: String) async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder where \(repo) is cloned."
        panel.prompt = "Link"
        if let current = localClones[repo] { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            localClones[repo] = try await clones.verify(url, repo: repo).path
            return true
        } catch {
            report(error, "Couldn't link the clone")
            return false
        }
    }

    /// Checks the PR's head branch out in its repo's clone, asking for the clone first when none is linked.
    /// Returns the branch checked out, or nil when it didn't happen.
    func checkOut(_ pr: PullRequest) async -> String? {
        guard !blockDemo(pr) else { return nil }
        if localClones[pr.repo] == nil, await !chooseClone(for: pr.repo) { return nil }
        guard let path = localClones[pr.repo], checkingOut.insert(path).inserted else { return nil }
        defer { checkingOut.remove(path) }
        do {
            return try await clones.checkout(pr.ref, in: URL(fileURLWithPath: path))
        } catch {
            report(error, "Couldn't check out \(pr.repo)#\(pr.number)")
            return nil
        }
    }

    /// Repos of the tracked PRs plus any already linked, for Settings.
    var knownRepos: [String] {
        Set(prs.values.filter { !$0.isDemo }.map(\.repo)).union(localClones.keys)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
