import Foundation
import Testing
@testable import ReviewDeskCore

private func commit(_ oid: String) -> PRCommit {
    PRCommit(oid: oid, abbreviatedOid: String(oid.prefix(7)), headline: oid, author: "alice", date: nil)
}

private let commits = [commit("c1"), commit("c2"), commit("c3")]

private func pr(head: String = "c3", reviewed: String? = nil) -> PullRequest {
    var pr = PullRequest(id: "PR_1", number: 1, title: "", url: "", state: "OPEN", isDraft: false, updatedAt: .now, headRefOid: head,
                         headRefName: "h", baseRefName: "main", author: "alice", repo: "o/r", commentCount: 0, reviewCount: 0,
                         threadCommentCount: 0, requestedReviewers: [])
    pr.viewerReviewedOid = reviewed
    return pr
}

@Test func detailDecodesCommitsOldestFirst() async throws {
    let runner = FakeRunner { _ in
        data(#"""
        {"node":{"body":"","comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]},"pending":{"nodes":[]},
          "commitCount":{"totalCount":140},
          "commits":{"nodes":[
            {"commit":{"oid":"c1full","abbreviatedOid":"c1","messageHeadline":"Add model","committedDate":"2026-10-01T00:00:00Z",
                       "author":{"name":"Alice A","user":{"login":"alice"}}}},
            {"commit":{"oid":"c2full","abbreviatedOid":"c2","messageHeadline":"Fix typo","committedDate":"2026-10-02T00:00:00Z",
                       "author":{"name":"Bob B","user":null}}}]}}}
        """#)
    }
    let detail = try await GitHub(runner: runner).detail(id: "PR_1")
    #expect(runner.calls.first?.query.contains("commits(last: 100)") == true)
    #expect(detail.commits.map(\.oid) == ["c1full", "c2full"])
    #expect(detail.commits.map(\.author) == ["alice", "Bob B"])
    #expect(detail.commitCount == 140)
    #expect(runner.calls.first?.query.contains("parents") == false) // a nested connection per commit doubled the query's cost
    #expect(detail.commits.first?.headline == "Add model")
    #expect(detail.commits.first?.date != nil)
}

@Test func selectionBoundsCompareFromTheFirstCommitsParent() throws {
    #expect(CommitSelection.all.bounds(commits: commits, pr: pr()) == nil)
    let one = try #require(CommitSelection.range(first: "c2", last: "c2").bounds(commits: commits, pr: pr()))
    #expect((one.base, one.head) == ("c2^", "c2"))
    let run = try #require(CommitSelection.range(first: "c1", last: "c3").bounds(commits: commits, pr: pr()))
    #expect((run.base, run.head) == ("c1^", "c3"))
    // A commit no longer in the pull request (force-pushed away) means the whole diff.
    #expect(CommitSelection.range(first: "gone", last: "c3").bounds(commits: commits, pr: pr()) == nil)
}

@Test func sinceReviewNeedsAReviewOnAnOlderCommit() throws {
    #expect(CommitSelection.sinceReview.bounds(commits: commits, pr: pr()) == nil)
    #expect(CommitSelection.sinceReview.bounds(commits: commits, pr: pr(reviewed: "c3")) == nil)
    let since = try #require(CommitSelection.sinceReview.bounds(commits: commits, pr: pr(reviewed: "c1")))
    #expect((since.base, since.head) == ("c1", "c3"))
}

@Test func aPushResetsTheSelectionUnlessItFollowsTheHead() {
    let one = CommitSelection.range(first: "c2", last: "c2")
    #expect(one.current(chosenAt: "c3", pr: pr()) == one)
    #expect(one.current(chosenAt: "c3", pr: pr(head: "c4")) == .all)
    #expect(CommitSelection.sinceReview.current(chosenAt: "c3", pr: pr(head: "c4")) == .sinceReview)
}

@Test func commitLinksFindThePullRequestsOwnCommits() throws {
    let full = [PRCommit(oid: "a1b2c3d4e5f6", abbreviatedOid: "a1b2c3d", headline: "", author: "", date: nil)]
    let link = try #require(URL(string: "https://github.com/O/R/commit/A1B2C3D"))
    #expect(PRCommit.linked(by: link, repo: "o/r", in: full)?.oid == "a1b2c3d4e5f6")
    #expect(PRCommit.linked(by: try #require(URL(string: "https://github.com/o/other/commit/a1b2c3d")), repo: "o/r", in: full) == nil)
    #expect(PRCommit.linked(by: try #require(URL(string: "https://github.com/o/r/commit/ffffff1")), repo: "o/r", in: full) == nil)
    #expect(PRCommit.linked(by: try #require(URL(string: "https://github.com/o/r/pull/1")), repo: "o/r", in: full) == nil)
}

@Test func commitViewsTakeCommentsOnlyOnNewSideLinesOfThePullRequestDiff() {
    let prAnchors: Set = [Anchor(path: "a.py", line: 4), Anchor(path: "a.py", line: 2, side: .left)]
    let atHead = CommitView(endsAtHead: true, prAnchors: prAnchors)
    #expect(atHead.accepts(Anchor(path: "a.py", line: 4)))
    #expect(!atHead.accepts(Anchor(path: "a.py", line: 5))) // only in the commit's diff
    #expect(!atHead.accepts(Anchor(path: "a.py", line: 2, side: .left))) // old side counts from another base
    #expect(atHead.shows(Anchor(path: "a.py", line: 9)))
    let earlier = CommitView(endsAtHead: false, prAnchors: prAnchors)
    #expect(!earlier.accepts(Anchor(path: "a.py", line: 4)))
    #expect(!earlier.shows(Anchor(path: "a.py", line: 4)))
}
