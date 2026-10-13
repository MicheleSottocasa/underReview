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
                "\(folder) has no remote on github.com/\(repo). Remote URLs must point at github.com (SSH host aliases aren't recognized)."
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
    static let operationMarkers = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "rebase-merge", "rebase-apply"]

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
        // Each line is "<name>\t<url> (fetch|push)".
        let remote = remotes.text.split(separator: "\n").first { line in
            line.split(whereSeparator: \.isWhitespace).dropFirst().first
                .flatMap { ClaudeAgents.repo(fromRemote: String($0)) }?.caseInsensitiveCompare(repo) == .orderedSame
        }?.split(whereSeparator: \.isWhitespace).first
        guard let remote else { throw Failure.otherRepo(folder: folder.path, repo: repo) }
        return (URL(fileURLWithPath: top.text.trimmingCharacters(in: .whitespacesAndNewlines)), String(remote))
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
