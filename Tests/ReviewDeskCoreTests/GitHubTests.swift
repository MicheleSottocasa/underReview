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
    let stamp = #"{"id":"A","updatedAt":"2026-10-12T14:27:55Z"}"#
    let runner = FakeRunner { _ in
        data(#"{"authored":{"nodes":[\#(stamp)]},"assigned":{"nodes":[\#(stamp)]},"requested":{"nodes":[{"id":"B","updatedAt":"2026-10-12T14:27:55Z"}]}}"#)
    }
    let inbox = try await GitHub(runner: runner).inbox()
    #expect(inbox.keys.sorted() == ["A", "B"])
    #expect(inbox["A"] == (try Date("2026-10-12T14:27:55Z", strategy: .iso8601)))
    // Regression: the full PR fragment in the searches cost 306 points per poll and exhausted the hourly limit.
    #expect(!(runner.calls.first?.query.contains("reviewThreads") ?? true))
}

@Test func readsUpdateTimesInChunksOfAHundred() async throws {
    let runner = FakeRunner { call in
        let ids = call.variables["ids"] as? [String] ?? []
        return data(#"{"nodes":[{"id":"\#(ids[0])","updatedAt":"2026-10-12T14:27:55Z"},null]}"#)
    }
    let stamps = try await GitHub(runner: runner).updatedAt(ids: (0..<150).map { "PR_\($0)" })
    #expect(stamps.keys.sorted() == ["PR_0", "PR_100"])
    #expect(runner.calls.map { ($0.variables["ids"] as? [String])?.count } == [100, 50])
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
          "reviewThreads":{"nodes":[{"id":"T_1","path":"a.swift","line":3,"diffSide":"LEFT","isResolved":false,"isOutdated":true,
            "comments":{"nodes":[{"id":"C_9","author":{"login":"me"},"body":"web comment","createdAt":"2026-10-01T00:00:00Z","state":"PENDING"}]}}]},
          "pending":{"nodes":[{"id":"R_2","commit":{"oid":"abc"},"comments":{"nodes":[{"id":"C_9","path":"a.swift","line":4,"body":"web comment"}]}}]}}}
        """#)
    }
    let detail = try await GitHub(runner: runner).detail(id: "PR_1")
    #expect(detail.comments.first?.author == "ghost")
    #expect(detail.reviews.map(\.id) == ["R_1"])
    #expect(detail.threads.first?.isOutdated == true)
    #expect(detail.threads.first?.side == .left)
    #expect(detail.threads.first?.comments.first?.isPending == true)
    #expect(detail.comments.first?.isPending == false)
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

@Test func batchSkipsUnresolvableIDsInsteadOfFailing() async throws {
    let runner = FakeRunner { _ in
        CommandResult(status: 1, stdout: Data(#"""
        {"data":{"nodes":[\#(prNode(id: "PR_ok")),null]},
         "errors":[{"type":"NOT_FOUND","path":["nodes",1],"message":"Could not resolve to a node with the global id of 'PR_gone'."}]}
        """#.utf8))
    }
    #expect(try await GitHub(runner: runner).pullRequests(ids: ["PR_ok", "PR_gone"]).map(\.id) == ["PR_ok"])
}

@Test func otherErrorsInBatchStillFail() async {
    let runner = FakeRunner { _ in
        CommandResult(status: 1, stdout: Data(#"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#.utf8))
    }
    await #expect(throws: GitHubError.graphQL(["API rate limit exceeded"])) {
        try await GitHub(runner: runner).pullRequests(ids: ["PR_1"])
    }
}

@Test func decodesTheViewersReviewState() async throws {
    let nodes = [
        prNode(id: "PENDING", pending: 4),
        prNode(id: "SENT", latestReview: "APPROVED", pending: nil),
        prNode(id: "MINE", author: true, threads: [(2, false, false, false), (3, true, false, false), (1, false, true, false)]),
        prNode(id: "REVIEWER", threads: [(2, false, false, true), (2, false, false, false)]),
    ]
    let runner = FakeRunner { _ in data(#"{"nodes":[\#(nodes.joined(separator: ","))]}"#) }
    let prs = try await GitHub(runner: runner).pullRequests(ids: ["x"])

    #expect(prs[0].pendingReviewComments == 4 && prs[0].viewerReviewState == nil)
    #expect(prs[1].pendingReviewComments == nil && prs[1].viewerReviewState == "APPROVED")
    // My PR: unresolved threads where someone else spoke last.
    #expect(prs[2].viewerIsAuthor && prs[2].threadsAwaitingReply == 1)
    // Someone else's PR: only threads I started count.
    #expect(prs[3].threadsAwaitingReply == 1)
}

@Test func readsViewedFilesAcrossPages() async throws {
    let runner = FakeRunner { call in
        call.variables["after"] == nil
            ? data(#"{"node":{"files":{"nodes":[{"path":"a","viewerViewedState":"VIEWED"},{"path":"b","viewerViewedState":"DISMISSED"}],"pageInfo":{"hasNextPage":true,"endCursor":"c1"}}}}"#)
            : data(#"{"node":{"files":{"nodes":[{"path":"c","viewerViewedState":"VIEWED"},{"path":"d","viewerViewedState":"UNVIEWED"}],"pageInfo":{"hasNextPage":false,"endCursor":"c2"}}}}"#)
    }
    #expect(try await GitHub(runner: runner).viewedFiles(prID: "PR_1") == ["a", "c"])
    #expect(runner.calls.map { $0.variables["after"] as? String } == [nil, "c1"])
}

@Test func marksAndUnmarksFilesAsViewed() async throws {
    let runner = FakeRunner { _ in data(#"{"x":{"clientMutationId":null}}"#) }
    let github = GitHub(runner: runner)
    try await github.setViewed(prID: "PR_1", path: "a.swift", viewed: true)
    try await github.setViewed(prID: "PR_1", path: "a.swift", viewed: false)
    #expect(runner.calls.map { $0.query.contains("unmarkFileAsViewed") } == [false, true])
    #expect(runner.calls.first?.variables["path"] as? String == "a.swift")
}

@Test func decodesCommentPermissionsAndReactions() {
    let comment = GitHub.decodeComment([
        "__typename": "PullRequestReviewComment", "id": "C_1", "author": ["login": "me"], "body": "x", "createdAt": "2026-10-01T00:00:00Z",
        "viewerCanUpdate": true, "viewerCanDelete": true, "viewerCanReact": true,
        "reactionGroups": [
            ["content": "HEART", "viewerHasReacted": true, "reactors": ["totalCount": 2]],
            ["content": "EYES", "viewerHasReacted": false, "reactors": ["totalCount": 0]],
        ],
    ])
    #expect(comment.kind == .review)
    #expect(comment.viewerCanUpdate && comment.viewerCanDelete && comment.viewerCanReact)
    #expect(comment.reactions == [Reaction(content: .heart, count: 2, viewerHasReacted: true)])
    #expect(GitHub.decodeComment(["id": "IC_1"]).kind == .issue)
}

@Test func editsDeletesAndReactsWithTheRightMutation() async throws {
    let runner = FakeRunner { _ in data(#"{"x":{"clientMutationId":null}}"#) }
    let github = GitHub(runner: runner)
    let issue = Comment(id: "IC_1", author: "me", body: "a", createdAt: .now)
    var review = issue
    review.kind = .review
    try await github.editComment(issue, body: "b")
    try await github.editComment(review, body: "b")
    try await github.deleteComment(issue)
    try await github.deleteComment(review)
    try await github.setReaction(.rocket, on: "IC_1", reacted: true)
    try await github.setReaction(.rocket, on: "IC_1", reacted: false)
    let mutations = runner.calls.map { $0.query.split(separator: "{")[1].split(separator: "(")[0].trimmingCharacters(in: .whitespaces) }
    #expect(mutations == ["updateIssueComment", "updatePullRequestReviewComment", "deleteIssueComment",
                          "deletePullRequestReviewComment", "addReaction", "removeReaction"])
    #expect(runner.calls.last?.variables["content"] as? String == "ROCKET")
}

@Test func readsFileContentsInBatchesSkippingBinaryAndTruncated() async throws {
    let runner = FakeRunner { call in
        let count = call.variables.keys.filter { $0.hasPrefix("e") }.count
        if count == 50 {
            return data(#"{"repository":{"f0":{"text":"a","isBinary":false,"isTruncated":false},"f1":{"text":null,"isBinary":true,"isTruncated":false},"f2":{"text":"x","isBinary":false,"isTruncated":true},"f3":null}}"#)
        }
        return data(#"{"repository":{"f0":{"text":"last","isBinary":false,"isTruncated":false}}}"#)
    }
    let paths = (0..<51).map { "p\($0)" }
    let contents = try await GitHub(runner: runner).fileContents(repo: "o/r", paths: paths, ref: "abc")
    #expect(contents == ["p0": "a", "p50": "last"])
    #expect(runner.calls.count == 2)
    #expect(runner.calls[0].variables["e1"] as? String == "abc:p1")
    #expect(runner.calls[1].variables["e0"] as? String == "abc:p50")
}

@Test func pendingReviewSkipsTheConversation() async throws {
    let runner = FakeRunner { _ in data(#"{"node":{"pending":{"nodes":[{"id":"R","commit":{"oid":"h"},"comments":{"nodes":[]}}]}}}"#) }
    #expect(try await GitHub(runner: runner).pendingReview(prID: "PR_1")?.id == "R")
    #expect(!(runner.calls.first?.query.contains("reviewThreads") ?? true))
}
