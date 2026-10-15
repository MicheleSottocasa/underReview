import Foundation

/// A repository's clone on this Mac, where a pull request's head branch can be checked out.
public struct LocalClone: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case notAClone(folder: String)
        case otherRepo(folder: String, repo: String)
        case uncommittedChanges(folder: String)
        case operationInProgress(folder: String, marker: String)
        case unreachableHead(folder: String)
        case untrackedFilesInTheWay(folder: String, paths: [String])
        case checkoutFailed(detail: String, branch: String)

        public var errorDescription: String? {
            switch self {
            case .notAClone(let folder): "\(folder) isn't a git clone."
            case .otherRepo(let folder, let repo):
                "\(folder) has no remote on github.com/\(repo). Remote URLs must point at github.com, directly or through an SSH host alias whose HostName is github.com."
            case .uncommittedChanges(let folder): "\(folder) has uncommitted changes. Commit or stash them, then check out again."
            case .operationInProgress(let folder, let marker):
                "\(folder) is in the middle of a git operation (\(marker)). Finish or abort it, then check out again."
            case .unreachableHead(let folder):
                "HEAD in \(folder) is detached on commits no branch contains. Put them on a branch, then check out again."
            case .untrackedFilesInTheWay(let folder, let paths):
                "The pull request adds files that already exist untracked or ignored in \(folder), and checking out would overwrite them: \(paths.joined(separator: ", ")). Move them away, then check out again."
            case .checkoutFailed(let detail, let branch):
                "\(detail)\nThe clone is now on \(branch.isEmpty ? "a detached HEAD" : branch)."
            }
        }
    }

    /// Files git leaves in its folder while an operation waits for the user; a checkout then would mix branches.
    /// `sequencer` outlives a resolved conflict in a multi-commit cherry-pick or revert, with a clean status.
    static let operationMarkers = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "rebase-merge", "rebase-apply",
                                   "sequencer"]

    let runner: any CommandRunner

    public init(runner: any CommandRunner) { self.runner = runner }

    /// Throws unless `folder` is in a git clone with a remote on `repo`: `origin`, or any other one such as the
    /// `upstream` of a fork. Returns the clone's top level, so a subfolder links the whole clone.
    @discardableResult
    public func verify(_ folder: URL, repo: String) async throws -> URL {
        try await clone(folder, repo: repo).top
    }

    /// The clone's top level and the name of its remote on `repo`.
    func clone(_ folder: URL, repo: String) async throws -> (top: URL, remote: String) {
        let top = try await runner.run("git", ["-C", folder.path, "rev-parse", "--show-toplevel"])
        let remotes = try await runner.run("git", ["-C", folder.path, "remote", "-v"])
        guard top.status == 0, remotes.status == 0 else { throw Failure.notAClone(folder: folder.path) }
        // Each line is "<name>\t<url> (fetch|push)". Only the fetch URL counts: that's where the PR is fetched from.
        let fetches: [(name: String, url: String)] = remotes.text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard line.hasSuffix("(fetch)"), fields.count >= 2 else { return nil }
            return (String(fields[0]), String(fields[1]))
        }
        let isRepo = { (url: String) in ClaudeAgents.repo(fromRemote: url)?.caseInsensitiveCompare(repo) == .orderedSame }
        var remote = fetches.first { isRepo($0.url) }?.name
        // An SSH host alias (`git@github-work:o/r`) counts when the SSH config points it at github.com.
        var hosts: [String: String] = [:]
        for fetch in fetches where remote == nil {
            guard let (alias, path) = Self.sshAlias(fetch.url) else { continue }
            if hosts[alias] == nil { hosts[alias] = await sshHostName(alias) ?? "" }
            if ["github.com", "ssh.github.com"].contains(hosts[alias]), isRepo("git@github.com:\(path)") { remote = fetch.name }
        }
        guard let remote else { throw Failure.otherRepo(folder: folder.path, repo: repo) }
        return (URL(fileURLWithPath: top.text.trimmingCharacters(in: .whitespacesAndNewlines)), remote)
    }

    /// The host and path of an SSH remote, `[user@]host:path` or `ssh://[user@]host[:port]/path`, when the host
    /// isn't a plain name git would treat as a local path.
    static func sshAlias(_ url: String) -> (host: String, path: String)? {
        let pattern = #"^(?:ssh://(?:[^@/]+@)?([A-Za-z0-9._-]+)(?::\d+)?/|(?:[^@/:]+@)?([A-Za-z0-9._-]+):(?!//))(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) else { return nil }
        let host = [1, 2].compactMap { Range(match.range(at: $0), in: url).map { String(url[$0]) } }.first
        guard let host, !host.hasPrefix("-"), let path = Range(match.range(at: 3), in: url) else { return nil }
        return (host, String(url[path]))
    }

    /// The real host name an SSH alias stands for, from `ssh -G` (reads the SSH config, never connects).
    func sshHostName(_ alias: String) async -> String? {
        guard let result = try? await runner.run("ssh", ["-G", "--", alias]), result.status == 0 else { return nil }
        return result.text.split(separator: "\n").first { $0.hasPrefix("hostname ") }
            .map { $0.dropFirst("hostname ".count).trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// Checks out the pull request's head branch with `gh pr checkout`, after making sure nothing in the clone can
    /// be lost or mixed up: no uncommitted changes to tracked files, no merge, rebase, cherry-pick, revert or bisect
    /// under way, no detached commits left unreachable, and no untracked or ignored file where the pull request adds
    /// one (git overwrites ignored files on checkout). `head` is the PR's head branch name, which gh reuses for the
    /// local branch. Returns the branch now checked out.
    @discardableResult
    public func checkout(_ pr: PRRef, head: String, in folder: URL) async throws -> String {
        let (top, remote) = try await clone(folder, repo: pr.nameWithOwner)
        let dir = top.path
        let status = try await runner.output("git", ["-C", dir, "status", "--porcelain", "--untracked-files=no"])
        guard status.isEmpty else { throw Failure.uncommittedChanges(folder: dir) }
        let gitDir = try await text("git", ["-C", dir, "rev-parse", "--absolute-git-dir"])
        if let marker = Self.operationMarkers.first(where: { FileManager.default.fileExists(atPath: "\(gitDir)/\($0)") }) {
            throw Failure.operationInProgress(folder: dir, marker: marker)
        }
        let onBranch = try await runner.run("git", ["-C", dir, "symbolic-ref", "-q", "HEAD"]).status == 0
        if !onBranch, try await text("git", ["-C", dir, "for-each-ref", "--contains", "HEAD", "--count=1"]).isEmpty {
            throw Failure.unreachableHead(folder: dir)
        }
        // ponytail: this fetch and gh's own are separate, so a push between them can add a file nobody checked.
        // Closing that means checking out FETCH_HEAD ourselves instead of running `gh pr checkout`.
        _ = try await runner.output("git", ["-C", dir, "fetch", remote, "refs/pull/\(pr.number)/head"], timeout: .seconds(180))
        var added = try await paths(dir, addedBy: "FETCH_HEAD")
        // With a same-named local branch, gh first checks out its old tip and then fast-forwards: an ignored file
        // that tip tracks would be overwritten, then deleted by the fast-forward.
        let localHead = "refs/heads/\(head)"
        if try await runner.run("git", ["-C", dir, "rev-parse", "--verify", "-q", localHead]).status == 0 {
            added += try await paths(dir, addedBy: localHead).filter { !added.contains($0) }
        }
        // The tree is clean, so a file the PR adds that is already on disk is untracked or ignored.
        let inTheWay = added.filter {
            (try? FileManager.default.attributesOfItem(atPath: top.appendingPathComponent($0).path)) != nil
        }
        guard inTheWay.isEmpty else { throw Failure.untrackedFilesInTheWay(folder: dir, paths: inTheWay) }
        do {
            // `--repo` keeps gh from asking which remote to use in a fork with several.
            _ = try await runner.output("gh", ["pr", "checkout", String(pr.number), "--repo", pr.nameWithOwner],
                                        cwd: top, timeout: .seconds(180))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // gh may have switched branches before failing (e.g. a same-named local branch that can't fast-forward).
            let branch = (try? await text("git", ["-C", dir, "branch", "--show-current"])) ?? ""
            throw Failure.checkoutFailed(detail: error.localizedDescription, branch: branch)
        }
        return try await text("git", ["-C", dir, "branch", "--show-current"])
    }

    /// The pull request's files at `sha`, in a detached worktree of the clone in a new temporary folder. The clone's
    /// own branch and files stay as they are, and every call gets its own worktree, so reviews can run side by side.
    /// Fetches the PR's head when the clone doesn't have `sha` yet. Remove it with `removeSnapshot`.
    public func snapshot(_ pr: PRRef, sha: String, from folder: URL) async throws -> URL {
        let (top, remote) = try await clone(folder, repo: pr.nameWithOwner)
        let dir = top.path
        if try await runner.run("git", ["-C", dir, "cat-file", "-e", "\(sha)^{commit}"]).status != 0 {
            // No FETCH_HEAD: concurrent snapshots would race on it, and the worktree needs only the objects.
            _ = try await runner.output("git", ["-C", dir, "fetch", "--no-write-fetch-head", remote, "refs/pull/\(pr.number)/head"],
                                        timeout: .seconds(180))
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reviewdesk-\(pr.repo)-\(pr.number)-\(UUID().uuidString)")
        // No hooks: the clone's post-checkout hook (husky, lefthook…) has no business running here.
        _ = try await runner.output("git", ["-C", dir, "-c", "core.hooksPath=/dev/null", "worktree", "add", "--detach", path.path, sha],
                                    timeout: .seconds(300))
        return path
    }

    /// Removes a `snapshot` of the clone at `folder`, and its folder.
    public func removeSnapshot(_ path: URL, from folder: URL) async {
        _ = try? await runner.run("git", ["-C", folder.path, "worktree", "remove", "--force", path.path])
        try? FileManager.default.removeItem(at: path)
    }

    /// Files `rev` has that HEAD doesn't. `--no-renames`: a rename or copy onto an ignored path
    /// (`git mv config.example .env`) is an addition too. `-z`: otherwise git C-quotes non-ASCII paths
    /// (`"caf\303\251.txt"`) and none would be found on disk.
    private func paths(_ dir: String, addedBy rev: String) async throws -> [String] {
        let out = try await runner.output("git", ["-C", dir, "diff", "--name-only", "-z", "--no-renames", "--diff-filter=A", "HEAD", rev])
        return String(decoding: out, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    private func text(_ tool: String, _ args: [String]) async throws -> String {
        String(decoding: try await runner.output(tool, args), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
