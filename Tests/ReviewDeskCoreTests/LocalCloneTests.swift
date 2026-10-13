import Foundation
import Testing
@testable import ReviewDeskCore

private let folder = URL(fileURLWithPath: "/Users/me/code/r")
private let pr = PRRef(nameWithOwner: "O/R", number: 7)
private let forkRemotes = """
origin\tgit@github.com:me/r.git (fetch)
origin\tgit@github.com:me/r.git (push)
upstream\thttps://github.com/o/r.git (fetch)
upstream\thttps://github.com/o/r.git (push)

"""

/// Answers `git remote -v`, `git status` and `git branch` like a clone; records `gh`.
private func clone(remotes: String = forkRemotes, status: String = "") -> FakeRunner {
    FakeRunner { call in
        switch (call.tool, call.args.dropFirst(2).first) {
        case ("git", "remote"): ok(remotes)
        case ("git", "status"): ok(status)
        case ("git", "branch"): ok("h7\n")
        default: ok("")
        }
    }
}

@Test func verifyAcceptsAnyRemoteOnTheRepo() async throws {
    try await LocalClone(runner: clone()).verify(folder, repo: "o/r")
    await #expect(throws: LocalClone.Failure.otherRepo(folder: folder.path, repo: "o/other")) {
        try await LocalClone(runner: clone()).verify(folder, repo: "o/other")
    }
}

@Test func verifyRejectsAFolderThatIsNotAClone() async {
    let runner = FakeRunner { _ in CommandResult(status: 128, stdout: Data(), stderr: "not a git repository") }
    await #expect(throws: LocalClone.Failure.notAClone(folder: folder.path)) {
        try await LocalClone(runner: runner).verify(folder, repo: "o/r")
    }
}

@Test func checkoutRunsGhInTheClone() async throws {
    let runner = clone()
    let branch = try await LocalClone(runner: runner).checkout(pr, in: folder)

    #expect(branch == "h7")
    let gh = try #require(runner.calls.first { $0.tool == "gh" })
    #expect(gh.args == ["pr", "checkout", "7", "--repo", "O/R"])
    #expect(gh.cwd == folder)
}

@Test func checkoutRefusesUncommittedChanges() async {
    let runner = clone(status: " M Sources/a.swift\n")
    await #expect(throws: LocalClone.Failure.uncommittedChanges(folder: folder.path)) {
        try await LocalClone(runner: runner).checkout(pr, in: folder)
    }
    #expect(!runner.calls.contains { $0.tool == "gh" })
}

@Test func checkoutRefusesAnotherRepo() async {
    let runner = clone(remotes: "origin\tgit@github.com:o/other.git (fetch)\n")
    await #expect(throws: LocalClone.Failure.otherRepo(folder: folder.path, repo: "O/R")) {
        try await LocalClone(runner: runner).checkout(pr, in: folder)
    }
    #expect(!runner.calls.contains { $0.tool == "gh" })
}
