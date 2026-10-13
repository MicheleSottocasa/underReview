import Foundation

/// A repository's clone on this Mac, where a pull request's head branch can be checked out.
public struct LocalClone: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case notAClone(folder: String)
        case otherRepo(folder: String, repo: String)
        case uncommittedChanges(folder: String)

        public var errorDescription: String? {
            switch self {
            case .notAClone(let folder): "\(folder) isn't a git clone."
            case .otherRepo(let folder, let repo): "\(folder) has no GitHub remote for \(repo)."
            case .uncommittedChanges(let folder): "\(folder) has uncommitted changes. Commit or stash them, then check out again."
            }
        }
    }

    let runner: any CommandRunner

    public init(runner: any CommandRunner) { self.runner = runner }

    /// Throws unless `folder` is a git clone with a remote on `repo`: `origin`, or any other one such as the
    /// `upstream` of a fork.
    public func verify(_ folder: URL, repo: String) async throws {
        let result = try await runner.run("git", ["-C", folder.path, "remote", "-v"])
        guard result.status == 0 else { throw Failure.notAClone(folder: folder.path) }
        // Each line is "<name>\t<url> (fetch|push)".
        let repos = result.text.split(separator: "\n").compactMap { line in
            line.split(whereSeparator: \.isWhitespace).dropFirst().first.flatMap { ClaudeAgents.repo(fromRemote: String($0)) }
        }
        guard repos.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) else {
            throw Failure.otherRepo(folder: folder.path, repo: repo)
        }
    }

    /// Checks out the pull request's head branch with `gh pr checkout`. Refuses when tracked files have uncommitted
    /// changes; untracked files are left to git, which stops by itself if the checkout would overwrite one.
    /// Returns the branch now checked out.
    @discardableResult
    public func checkout(_ pr: PRRef, in folder: URL) async throws -> String {
        try await verify(folder, repo: pr.nameWithOwner)
        let status = try await runner.output("git", ["-C", folder.path, "status", "--porcelain", "--untracked-files=no"])
        guard status.isEmpty else { throw Failure.uncommittedChanges(folder: folder.path) }
        // `--repo` keeps gh from asking which remote to use in a fork with several.
        _ = try await runner.output("gh", ["pr", "checkout", String(pr.number), "--repo", pr.nameWithOwner],
                                    cwd: folder, timeout: .seconds(180))
        let branch = try await runner.output("git", ["-C", folder.path, "branch", "--show-current"])
        return String(decoding: branch, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
