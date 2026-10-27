import Foundation
import Testing
@testable import ReviewDeskCore

private let pr = PRRef(nameWithOwner: "O/R", number: 7)
private let forkRemotes = """
origin\tgit@github.com:me/r.git (fetch)
origin\tgit@github.com:me/r.git (push)
upstream\thttps://github.com/o/r.git (fetch)
upstream\thttps://github.com/o/r.git (push)

"""

/// A throwaway folder standing in for the clone's top level, with an empty `.git` folder. No git runs in it:
/// git's answers come from `fake`.
private func tempClone() throws -> URL {
    let top = FileManager.default.temporaryDirectory.appendingPathComponent("clone-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: top.appendingPathComponent(".git"), withIntermediateDirectories: true)
    return top
}

/// Answers git like a clean clone of o/r on a branch, at `top`; the PR adds `added`. A non-nil `localBranchAdds`
/// is a local `h7` branch whose tip adds those files. `gh` succeeds unless told not to.
private func fake(_ top: URL, remotes: String = forkRemotes, status: String = "", onBranch: Bool = true,
                  containing: String = "refs/heads/main", added: String = "", localBranchAdds: String? = nil,
                  ghFails: Bool = false, sshHosts: [String: String] = [:], hasCommit: Bool = true) -> FakeRunner {
    FakeRunner { call in
        if call.tool == "ssh" { return ok("user git\nhostname \(sshHosts[call.args.last ?? ""] ?? call.args.last ?? "")\nport 22\n") }
        if call.tool == "gh" {
            return ghFails ? CommandResult(status: 1, stdout: Data(), stderr: "not possible to fast-forward") : ok("")
        }
        switch Array(call.args.dropFirst(2)) {
        case ["rev-parse", "--show-toplevel"]: return ok(top.path + "\n")
        case ["rev-parse", "--absolute-git-dir"]: return ok(top.appendingPathComponent(".git").path + "\n")
        case ["remote", "-v"]: return ok(remotes)
        case ["symbolic-ref", "-q", "HEAD"]: return CommandResult(status: onBranch ? 0 : 1, stdout: Data("refs/heads/main\n".utf8))
        case ["for-each-ref", "--contains", "HEAD", "--count=1"]: return ok(containing)
        case ["branch", "--show-current"]: return ok(ghFails ? "h7-old\n" : "h7\n")
        case ["rev-parse", "--verify", "-q", "refs/heads/h7"]: return CommandResult(status: localBranchAdds == nil ? 1 : 0, stdout: Data())
        case let args where args.first == "status": return ok(status)
        case let args where args.first == "cat-file": return CommandResult(status: hasCommit ? 0 : 1, stdout: Data())
        // Like git, a rename onto a new path isn't an addition unless renames are off, and without `-z`
        // non-ASCII paths come back C-quoted.
        case let args where args.first == "diff":
            guard args.contains("--no-renames") else { return ok("") }
            let paths = (args.last == "refs/heads/h7" ? localBranchAdds ?? "" : added).split(separator: "\n")
            return ok(args.contains("-z") ? paths.map { "\($0)\0" }.joined() : paths.map(cQuoted).joined(separator: "\n"))
        default: return ok("")
        }
    }
}

/// `café.txt` → `"caf\303\251.txt"`, as git prints a non-ASCII path without `-z`.
private func cQuoted(_ path: Substring) -> String {
    guard !path.utf8.allSatisfy({ $0 < 128 }) else { return String(path) }
    return "\"" + path.utf8.map { $0 < 128 ? String(UnicodeScalar($0)) : String(format: "\\%03o", $0) }.joined() + "\""
}

@Test func verifyAcceptsAnyRemoteOnTheRepoAndReturnsTheTopLevel() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    let linked = try await LocalClone(runner: fake(top)).verify(top.appendingPathComponent("Sources"), repo: "o/r")
    #expect(linked.path == top.path)
    await #expect(throws: LocalClone.Failure.otherRepo(folder: top.path, repo: "o/other")) {
        try await LocalClone(runner: fake(top)).verify(top, repo: "o/other")
    }
}

@Test func verifyIgnoresAPushURLOnTheRepo() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    // `origin` fetches another repo and only pushes to o/r: fetching the PR from it would fail or get the wrong one.
    let remotes = "origin\tgit@github.com:me/r.git (fetch)\norigin\tgit@github.com:o/r.git (push)\n"
    await #expect(throws: LocalClone.Failure.otherRepo(folder: top.path, repo: "o/r")) {
        try await LocalClone(runner: fake(top, remotes: remotes)).verify(top, repo: "o/r")
    }
}

@Test func verifyAcceptsSSHRemotesWithASlashOrAHostAlias() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    // `git@github.com:/o/r.git` is a valid scp-like URL with a leading slash in the path.
    let slashed = "origin\tgit@github.com:/o/r.git (fetch)\norigin\tgit@github.com:/o/r.git (push)\n"
    #expect(try await LocalClone(runner: fake(top, remotes: slashed)).verify(top, repo: "o/r").path == top.path)

    // Host aliases count only when `ssh -G` says their HostName is github.com.
    let aliased = """
    evil\tgit@gitlab-alias:o/r.git (fetch)
    work\tgit@github-work:/o/r.git (fetch)
    other\tssh://git@github-work/o/other.git (fetch)

    """
    let runner = fake(top, remotes: aliased, sshHosts: ["gitlab-alias": "gitlab.com", "github-work": "github.com"])
    #expect(try await LocalClone(runner: runner).clone(top, repo: "o/r").remote == "work")
    #expect(try await LocalClone(runner: runner).clone(top, repo: "o/other").remote == "other")
    await #expect(throws: LocalClone.Failure.otherRepo(folder: top.path, repo: "o/gl")) {
        try await LocalClone(runner: runner).verify(top, repo: "o/gl")
    }
    // Each alias is looked up once, as a single argument after `--`.
    let lookups = runner.calls.filter { $0.tool == "ssh" }.map(\.args)
    #expect(lookups.allSatisfy { $0.count == 3 && $0[0] == "-G" && $0[1] == "--" })
}

@Test func sshAliasParsesSCPAndSSHURLsButNotLocalPathsOrOptions() {
    #expect(LocalClone.sshAlias("git@github-work:o/r.git")! == ("github-work", "o/r.git"))
    #expect(LocalClone.sshAlias("ssh://git@github-work:2222/o/r")! == ("github-work", "o/r"))
    #expect(LocalClone.sshAlias("host:/o/r")! == ("host", "/o/r"))
    #expect(LocalClone.sshAlias("/Users/me/r") == nil)
    #expect(LocalClone.sshAlias("https://github.com/o/r") == nil)
    #expect(LocalClone.sshAlias("-oProxyCommand=x:o/r") == nil)
}

@Test func verifyRejectsAFolderThatIsNotAClone() async {
    let folder = URL(fileURLWithPath: "/Users/me/code/r")
    let runner = FakeRunner { _ in CommandResult(status: 128, stdout: Data(), stderr: "not a git repository") }
    await #expect(throws: LocalClone.Failure.notAClone(folder: folder.path)) {
        try await LocalClone(runner: runner).verify(folder, repo: "o/r")
    }
}

@Test func checkoutFetchesFromTheRepoRemoteThenRunsGhInTheClone() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    let runner = fake(top)
    let branch = try await LocalClone(runner: runner).checkout(pr, head: "h7", in: top)

    #expect(branch == "h7")
    #expect(runner.calls.contains { $0.args == ["-C", top.path, "fetch", "upstream", "refs/pull/7/head"] })
    let gh = try #require(runner.calls.first { $0.tool == "gh" })
    #expect(gh.args == ["pr", "checkout", "7", "--repo", "O/R"])
    #expect(gh.cwd?.path == top.path)
}

/// Each case must stop before gh runs.
private func expectRefusal(_ failure: LocalClone.Failure, _ top: URL, _ runner: FakeRunner) async {
    await #expect(throws: failure) { try await LocalClone(runner: runner).checkout(pr, head: "h7", in: top) }
    #expect(!runner.calls.contains { $0.tool == "gh" })
}

@Test func checkoutRefusesUncommittedChangesAndAnotherRepo() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    await expectRefusal(.uncommittedChanges(folder: top.path), top, fake(top, status: " M Sources/a.swift\n"))
    await expectRefusal(.otherRepo(folder: top.path, repo: "O/R"), top,
                        fake(top, remotes: "origin\tgit@github.com:o/other.git (fetch)\n"))
}

@Test func checkoutRefusesDuringARebaseMergeOrBisect() async throws {
    for marker in LocalClone.operationMarkers {
        let top = try tempClone()
        defer { try? FileManager.default.removeItem(at: top) }
        FileManager.default.createFile(atPath: top.appendingPathComponent(".git/\(marker)").path, contents: Data())
        await expectRefusal(.operationInProgress(folder: top.path, marker: marker), top, fake(top))
    }
}

@Test func checkoutRefusesBetweenTheCommitsOfACherryPick() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    // `git cherry-pick a..b` after a resolved conflict: only the sequencer folder is left, and the status is clean.
    try FileManager.default.createDirectory(at: top.appendingPathComponent(".git/sequencer"), withIntermediateDirectories: true)
    await expectRefusal(.operationInProgress(folder: top.path, marker: "sequencer"), top, fake(top))
}

@Test func checkoutRefusesADetachedHeadNoBranchContains() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    await expectRefusal(.unreachableHead(folder: top.path), top, fake(top, onBranch: false, containing: ""))
    // Detached on a commit a branch has is fine.
    _ = try await LocalClone(runner: fake(top, onBranch: false)).checkout(pr, head: "h7", in: top)
}

@Test func checkoutRefusesWhenThePRAddsAFileAlreadyOnDisk() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    // e.g. an ignored `.env.local` the PR starts tracking: git would overwrite it.
    FileManager.default.createFile(atPath: top.appendingPathComponent(".env.local").path, contents: Data("SECRET=1".utf8))
    await expectRefusal(.untrackedFilesInTheWay(folder: top.path, paths: [".env.local"]), top,
                        fake(top, added: "docs/new.md\n.env.local\n"))
}

@Test func checkoutRefusesWhenThePRRenamesAFileOntoOneAlreadyOnDisk() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    // `git mv config.example .env` in the PR, with an ignored `.env` in the clone.
    FileManager.default.createFile(atPath: top.appendingPathComponent(".env").path, contents: Data("SECRET=1".utf8))
    await expectRefusal(.untrackedFilesInTheWay(folder: top.path, paths: [".env"]), top, fake(top, added: ".env\n"))
}

@Test func checkoutFindsNonASCIIPathsThePRAddsOnDisk() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    FileManager.default.createFile(atPath: top.appendingPathComponent("café.txt").path, contents: Data())
    await expectRefusal(.untrackedFilesInTheWay(folder: top.path, paths: ["café.txt"]), top, fake(top, added: "café.txt\n"))
}

@Test func checkoutChecksTheFilesASameNamedLocalBranchAdds() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    // gh switches to the local `h7` tip first, which tracks `.env`; the PR's head no longer does.
    FileManager.default.createFile(atPath: top.appendingPathComponent(".env").path, contents: Data("SECRET=1".utf8))
    await expectRefusal(.untrackedFilesInTheWay(folder: top.path, paths: [".env"]), top,
                        fake(top, added: "docs/new.md\n", localBranchAdds: ".env\ndocs/new.md\n"))
    // Without that branch, only the PR's head counts.
    _ = try await LocalClone(runner: fake(top, added: "docs/new.md\n")).checkout(pr, head: "h7", in: top)
}

@Test func failedCheckoutSaysWhereTheCloneIsNow() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    do {
        try await LocalClone(runner: fake(top, ghFails: true)).checkout(pr, head: "h7", in: top)
        Issue.record("expected a failure")
    } catch LocalClone.Failure.checkoutFailed(_, let branch) {
        #expect(branch == "h7-old")
    }
}

// Regression: /code-review had no checkout and tried to clone; a shared clone would need the PR's branch checked out.
@Test func snapshotFetchesAMissingHeadAndAddsADetachedWorktreeWithoutHooks() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    let runner = fake(top, hasCommit: false)
    let path = try await LocalClone(runner: runner).snapshot(pr, sha: "abc", from: top)
    let git = runner.calls.filter { $0.tool == "git" }.map(\.args)
    #expect(git.contains(["-C", top.path, "fetch", "--no-write-fetch-head", "upstream", "refs/pull/7/head"]))
    #expect(git.last == ["-C", top.path, "-c", "core.hooksPath=/dev/null", "worktree", "add", "--detach", path.path, "abc"])
    let other = try await LocalClone(runner: runner).snapshot(pr, sha: "abc", from: top)
    #expect(other != path)
}

@Test func snapshotSkipsTheFetchWhenTheCloneHasTheCommit() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    let runner = fake(top)
    _ = try await LocalClone(runner: runner).snapshot(pr, sha: "abc", from: top)
    #expect(!runner.calls.contains { $0.args.contains("fetch") })
}

@Test func currentBranchReadsTheClonesBranch() async throws {
    let top = try tempClone()
    defer { try? FileManager.default.removeItem(at: top) }
    #expect(await LocalClone(runner: fake(top)).currentBranch(in: top) == "h7")
    let failing = FakeRunner { _ in CommandResult(status: 128, stdout: Data(), stderr: "not a git repository") }
    #expect(await LocalClone(runner: failing).currentBranch(in: top) == nil)
}
