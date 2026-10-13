import AppKit
import ReviewDeskCore
import UniformTypeIdentifiers

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
            return try await clones.checkout(pr.ref, head: pr.headRefName, in: URL(fileURLWithPath: path))
        } catch {
            report(error, "Couldn't check out \(pr.repo)#\(pr.number)")
            return nil
        }
    }

    /// The editor link template chosen in Settings › Repositories; empty opens the file in the default text editor.
    static let editorKey = "editorURL"

    /// Opens a changed file from the repo's clone in the user's editor, at `line` or else at its first change.
    /// Asks for the clone first when none is linked.
    func openInEditor(_ pr: PullRequest, file: FileChange, line: Int? = nil) async {
        guard !blockDemo(pr) else { return }
        if localClones[pr.repo] == nil, await !chooseClone(for: pr.repo) { return }
        guard let clone = localClones[pr.repo] else { return }
        let url: URL
        do {
            url = try EditorLink.file(file.filename, inClone: URL(fileURLWithPath: clone))
        } catch {
            report(error)
            return
        }
        let template = UserDefaults.standard.string(forKey: Self.editorKey) ?? ""
        guard !template.isEmpty else {
            // Security boundary: never the file's own default app, i.e. a double-click. Files from a pull request
            // carry no quarantine, so a script, `.command` or app would run. Always open it as text.
            guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
                lastError = "No text editor found. Pick an editor in Settings › Repositories."
                return
            }
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                report(error, "Couldn't open \(file.filename)")
            }
            return
        }
        let line = line ?? EditorLink.firstChange(in: file.patch ?? "")
        guard let link = EditorLink.url(template: template, path: url.path, line: line),
              NSWorkspace.shared.urlForApplication(toOpen: link) != nil else {
            lastError = "“\(template)” isn't an editor link any app opens (file: links aren't allowed). Pick another editor in Settings › Repositories."
            return
        }
        NSWorkspace.shared.open(link)
    }

    /// Repos of the tracked PRs plus any already linked, for Settings.
    var knownRepos: [String] {
        Set(prs.values.filter { !$0.isDemo }.map(\.repo)).union(localClones.keys)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
