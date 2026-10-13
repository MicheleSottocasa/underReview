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
                  ghFails: Bool = false) -> FakeRunner {
    FakeRunner { call in
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
