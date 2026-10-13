import Foundation
import Testing
@testable import ReviewDeskCore

@Test func countsTheCommitsPushedSinceAnOlderHead() async throws {
    let runner = FakeRunner { _ in ok("3\n") }
    #expect(try await GitHub(runner: runner).commitsAhead(repo: "o/r", from: "old", to: "new") == 3)
    #expect(runner.calls.first?.args == ["api", "repos/o/r/compare/old...new", "--jq", #"if .status == "ahead" then .ahead_by else null end"#])
    #expect(GitHub.compareURL(repo: "o/r", from: "old", to: "new")?.absoluteString == "https://github.com/o/r/compare/old..new")
}

@Test func aRebasedHeadHasNoCommitCount() async throws {
    // After a rebase or force-push the compare is "diverged": its ahead_by counts the rebased commits, not the new ones.
    let runner = FakeRunner { _ in ok("null\n") }
    #expect(try await GitHub(runner: runner).commitsAhead(repo: "o/r", from: "old", to: "new") == nil)
}

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
    #expect((pr.additions, pr.deletions, pr.changedFiles) == (120, 7, 3))
    #expect(pr.mergeable == "CONFLICTING" && pr.mergeStateStatus == "DIRTY" && pr.hasConflicts && !pr.isBehind)
    #expect(runner.calls.first?.query.contains("mergeable mergeStateStatus") == true)
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
          "reviewThreads":{"nodes":[{"id":"T_1","path":"a.swift","line":3,"diffSide":"LEFT","isResolved":false,"isOutdated":true,"resolvedBy":{"login":"bob"},
            "comments":{"nodes":[{"id":"C_9","author":{"login":"me"},"body":"web comment","createdAt":"2026-10-01T00:00:00Z","state":"PENDING","pullRequestReview":{"id":"R_2"},
              "diffHunk":"@@ -1 +1 @@\n+x"}]}}]},
          "pending":{"nodes":[{"id":"R_2","commit":{"oid":"abc"},"comments":{"nodes":[{"id":"C_9","path":"a.swift","line":4,"body":"web comment"}]}}]}}}
        """#)
    }
    let detail = try await GitHub(runner: runner).detail(id: "PR_1")
    #expect(detail.comments.first?.author == "ghost")
    #expect(detail.reviews.map(\.id) == ["R_1"])
    #expect(detail.threads.first?.isOutdated == true)
    #expect(detail.threads.first?.side == .left)
    #expect(detail.threads.first?.resolvedBy == "bob")
    #expect(detail.threads.first?.comments.first?.isPending == true)
    #expect(detail.threads.first?.comments.first?.reviewID == "R_2")
    #expect(detail.threads.first?.diffHunk == "@@ -1 +1 @@\n+x")
    #expect(detail.comments.first?.reviewID == nil)
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

@Test func decodesEveryoneElsesLatestReview() async throws {
    func review(_ state: String, _ login: String, mine: Bool = false) -> String {
        #"{"state":"\#(state)","viewerDidAuthor":\#(mine),"author":{"login":"\#(login)"}}"#
    }
    // dave approved, then replied in a thread: his latest review is COMMENTED, his latest opinionated one APPROVED.
    let latest = [review("APPROVED", "bob"), review("CHANGES_REQUESTED", "carol"), review("COMMENTED", "me", mine: true),
                  review("COMMENTED", "dave"), review("COMMENTED", "erin")]
    let opinionated = [review("APPROVED", "bob"), review("CHANGES_REQUESTED", "carol"), review("APPROVED", "dave")]
    let reviews = #""latestReviews":{"nodes":[\#(latest.joined(separator: ","))]},"latestOpinionatedReviews":{"nodes":[\#(opinionated.joined(separator: ","))]},"#
    let node = prNode(author: true).replacingOccurrences(of: #""stack":"#, with: reviews + #""stack":"#)
    let runner = FakeRunner { _ in data(#"{"nodes":[\#(node),\#(prNode(id: "NONE"))]}"#) }
    let prs = try await GitHub(runner: runner).pullRequests(ids: ["x"])

    // My own review is left out; dave's approval survives his later comment; erin only commented.
    #expect(prs[0].reviewsByOthers == ["bob": "APPROVED", "carol": "CHANGES_REQUESTED", "dave": "APPROVED", "erin": "COMMENTED"])
    #expect(prs[1].reviewsByOthers.isEmpty)
    #expect(runner.calls.first?.query.contains("latestOpinionatedReviews") == true)
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

@Test func namesReactionsLikeGitHub() {
    #expect(ReactionContent.allCases.map(\.name) == ["+1", "-1", "Laugh", "Hooray", "Confused", "Heart", "Rocket", "Eyes"])
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

@Test func resolvesThreadsAndHidesConversationCommentsAsResolved() async throws {
    let runner = FakeRunner { _ in data(#"{"x":{"clientMutationId":null}}"#) }
    let github = GitHub(runner: runner)
    try await github.setResolved(threadID: "T_1", resolved: true)
    try await github.setResolved(threadID: "T_1", resolved: false)
    try await github.setHiddenAsResolved(commentID: "IC_1", hidden: true)
    try await github.setHiddenAsResolved(commentID: "IC_1", hidden: false)
    let queries = runner.calls.map(\.query)
    #expect(queries[0].contains("resolveReviewThread(") && !queries[0].contains("unresolve"))
    #expect(queries[1].contains("unresolveReviewThread("))
    #expect(queries[2].contains("minimizeComment(") && queries[2].contains("classifier: RESOLVED"))
    #expect(queries[3].contains("unminimizeComment("))
    #expect(GitHub.decodeComment(["id": "IC_1", "isMinimized": true, "viewerCanMinimize": true]).isMinimized)
}

@Test func flagsPullRequestsChangedSinceTheViewersReview() async throws {
    let nodes = [
        prNode(id: "MOVED", head: "bbb", latestReview: "APPROVED", reviewedAt: "aaa"),
        prNode(id: "SAME", head: "aaa", latestReview: "COMMENTED", reviewedAt: "aaa"),
        prNode(id: "NEVER", head: "bbb"),
        prNode(id: "MINE", head: "bbb", author: true, latestReview: "COMMENTED", reviewedAt: "aaa"),
        prNode(id: "MERGED", head: "bbb", state: "MERGED", latestReview: "APPROVED", reviewedAt: "aaa"),
        prNode(id: "DISMISSED", head: "bbb", latestReview: "DISMISSED", reviewedAt: "aaa"),
    ]
    let runner = FakeRunner { _ in data(#"{"nodes":[\#(nodes.joined(separator: ","))]}"#) }
    let prs = try await GitHub(runner: runner).pullRequests(ids: ["x"])
    #expect(prs.first?.viewerReviewedOid == "aaa")
    #expect(prs.filter(\.needsReReview).map(\.id) == ["MOVED", "DISMISSED"])
}

@Test func summarizesThreadParticipantsAndTopic() {
    let comment = { (author: String, body: String) in Comment(id: author, author: author, body: body, createdAt: .now) }
    var thread = ReviewThread(id: "T", path: "a", line: 1, side: .right, isResolved: true, isOutdated: false, comments: [
        comment("alice", "\n  Why a loop here?  \nIt's slow."), comment("me", "ok"), comment("alice", "thanks"),
    ])
    #expect(thread.participants == ["alice", "me"])
    #expect(thread.participantList(viewer: "me") == "alice, you")
    #expect(thread.topic == "Why a loop here?")
    thread.comments[0].body = "```suggestion\nreturn x\n```"
    #expect(thread.topic == "return x")
    thread.comments += ["bob", "carol", "dan"].map { comment($0, "") }
    #expect(thread.participantList(viewer: "me") == "alice, you, bob +2")
    thread.comments = []
    #expect(thread.topic == "")
}

@Test func tellsWhetherAThreadInvolvesTheViewer() {
    let thread = { (comments: [(String, String)]) in
        ReviewThread(id: "T", path: "a", line: 1, side: .right, isResolved: false, isOutdated: false,
                     comments: comments.map { Comment(id: $0.0, author: $0.0, body: $0.1, createdAt: .now) })
    }
    let started = thread([("me", "why?"), ("bob", "because")])
    #expect(started.isStarted(by: "me") && started.hasComment(from: "me") && started.involves("me"))
    let replied = thread([("bob", "why?"), ("me", "because")])
    #expect(!replied.isStarted(by: "me") && replied.hasComment(from: "me") && replied.involves("me"))
    #expect(thread([("bob", "cc @Me, thoughts?")]).involves("me"))
    #expect(!thread([("bob", "ask @me-too or mail x@me")]).involves("me"))
    #expect(!thread([("bob", "why?")]).involves("me"))
    var pendingReply = thread([("bob", "why?")])
    pendingReply.comments.append(Comment(id: "C", author: "me", body: "draft", createdAt: .now, isPending: true))
    #expect(pendingReply.involves("me"))
    #expect(!started.involves("") && !started.isStarted(by: ""))
}

@Test func refetchesOnlyPullRequestsUpdatedSinceTheCache() async throws {
    let runner = FakeRunner { _ in data(#"{"nodes":[\#(prNode(id: "PR_2", number: 2))]}"#) }
    let github = GitHub(runner: runner)
    var cached = try #require(try await github.pullRequests(ids: ["PR_2"]).first)
    cached.id = "PR_1"
    let moved = cached.updatedAt.addingTimeInterval(60)

    let (prs, fetched) = try await github.pullRequests(
        updatedAt: ["PR_1": cached.updatedAt, "PR_2": moved], cached: ["PR_1": cached, "PR_gone": cached])

    #expect(fetched == ["PR_2"])
    #expect(runner.calls.last?.variables["ids"] as? [String] == ["PR_2"])
    #expect(prs.keys.sorted() == ["PR_1", "PR_2"]) // PR_gone left the inbox: dropped, not kept from the cache
    #expect(prs["PR_1"] == cached)

    let calls = runner.calls.count
    _ = try await github.pullRequests(updatedAt: ["PR_1": cached.updatedAt], cached: ["PR_1": cached])
    #expect(runner.calls.count == calls) // nothing changed: no request at all
}
