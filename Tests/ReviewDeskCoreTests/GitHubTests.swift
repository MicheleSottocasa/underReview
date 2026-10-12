import Foundation
import Testing
@testable import ReviewDeskCore

@Test func parsesPullRequestReferences() {
    #expect(PRRef("https://github.com/o/r/pull/12/files") == PRRef(nameWithOwner: "o/r", number: 12))
    #expect(PRRef("  o/r#7 ") == PRRef(nameWithOwner: "o/r", number: 7))
    #expect(PRRef("https://github.com/o/r/issues/3") == nil)
    #expect(PRRef("https://gitlab.com/o/r/pull/3") == nil)
    #expect(PRRef("nonsense") == nil)
}

@Test func decodesPullRequestWithNativeStack() async throws {
    let stack = #"{"number":4,"entries":{"nodes":[{"position":2,"pullRequest":{"id":"PR_2","number":2}},{"position":1,"pullRequest":{"id":"PR_1","number":1}}]}}"#
    let runner = FakeRunner { _ in data(#"{"nodes":[\#(prNode(threadComments: [2, 1], requested: ["me"], stack: stack)), null]}"#) }

    let prs = try await GitHub(runner: runner).pullRequests(ids: ["PR_1", "PR_gone"])

    #expect(prs.count == 1)
    let pr = try #require(prs.first)
    #expect(pr.threadCommentCount == 3)
    #expect(pr.requestedReviewers == ["me"])
    #expect(pr.stack?.entries.map(\.id) == ["PR_1", "PR_2"])
    #expect(pr.stackPosition == 1)
    #expect(runner.calls.first?.args == ["api", "graphql", "--input", "-"])
    #expect(runner.calls.first?.variables["ids"] as? [String] == ["PR_1", "PR_gone"])
}

@Test func batchesPollingInChunksOfFifty() async throws {
    let runner = FakeRunner { _ in data(#"{"nodes":[]}"#) }
    _ = try await GitHub(runner: runner).pullRequests(ids: (0..<120).map { "PR_\($0)" })
    #expect(runner.calls.map { ($0.variables["ids"] as? [String])?.count } == [50, 50, 20])
}

@Test func inboxMergesSearchesWithoutDuplicates() async throws {
    let runner = FakeRunner { _ in
        data(#"{"authored":{"nodes":[\#(prNode(id: "A"))]},"assigned":{"nodes":[\#(prNode(id: "A"))]},"requested":{"nodes":[\#(prNode(id: "B", number: 2))]}}"#)
    }
    #expect(try await GitHub(runner: runner).inbox().map(\.id) == ["A", "B"])
}

@Test func surfacesGraphQLErrors() async {
    let runner = FakeRunner { _ in CommandResult(status: 1, stdout: Data(#"{"errors":[{"message":"Could not resolve"}]}"#.utf8), stderr: "gh: Could not resolve") }
    await #expect(throws: GitHubError.graphQL(["Could not resolve"])) {
        try await GitHub(runner: runner).graphql("query { viewer { login } }")
    }
}

@Test func surfacesRateLimitFailures() async {
    let runner = FakeRunner { _ in CommandResult(status: 1, stdout: Data(), stderr: "gh: API rate limit exceeded (HTTP 403)") }
    await #expect(throws: CommandError.failed(tool: "gh", status: 1, stderr: "gh: API rate limit exceeded (HTTP 403)")) {
        try await GitHub(runner: runner).inbox()
    }
}

@Test func reportsMissingLogin() async {
    let runner = FakeRunner { _ in CommandResult(status: 1, stdout: Data(), stderr: "not logged in") }
    await #expect(throws: GitHubError.notLoggedIn("not logged in")) { try await GitHub(runner: runner).viewerLogin() }
}

@Test func detailSeparatesPendingReviewFromSubmittedOnes() async throws {
    let runner = FakeRunner { _ in
        data(#"""
        {"node":{"body":"desc",
          "comments":{"nodes":[{"id":"IC_1","author":null,"body":"hi","createdAt":"2026-10-01T00:00:00Z"}]},
          "reviews":{"nodes":[{"id":"R_1","author":{"login":"bob"},"state":"APPROVED","body":"","submittedAt":"2026-10-01T00:00:00Z"},
                              {"id":"R_2","author":{"login":"me"},"state":"PENDING","body":"","submittedAt":null}]},
          "reviewThreads":{"nodes":[{"id":"T_1","path":"a.swift","line":3,"isResolved":false,"isOutdated":true,"comments":{"nodes":[]}}]},
          "pending":{"nodes":[{"id":"R_2","commit":{"oid":"abc"},"comments":{"nodes":[{"id":"C_9","path":"a.swift","line":4,"body":"web comment"}]}}]}}}
        """#)
    }
    let detail = try await GitHub(runner: runner).detail(id: "PR_1")
    #expect(detail.comments.first?.author == "ghost")
    #expect(detail.reviews.map(\.id) == ["R_1"])
    #expect(detail.threads.first?.isOutdated == true)
    #expect(detail.pendingReview == PendingReview(id: "R_2", commitOID: "abc", comments: [PendingComment(id: "C_9", path: "a.swift", line: 4, body: "web comment")]))
}

@Test func filesFlattenSlurpedPages() async throws {
    let runner = FakeRunner { _ in
        ok(#"[[{"filename":"a","status":"modified","additions":1,"deletions":0,"patch":"@@ -1 +1 @@"}],[{"filename":"big.bin","status":"added","additions":0,"deletions":0}]]"#)
    }
    let files = try await GitHub(runner: runner).files(PRRef(nameWithOwner: "o/r", number: 1))
    #expect(files.map(\.filename) == ["a", "big.bin"])
    #expect(files[1].patch == nil)
}
