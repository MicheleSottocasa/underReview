import Foundation
import Testing
@testable import ReviewDeskCore

@Test func demoIsAStackOfTwoThroughTheRealHelpers() throws {
    let items = Stacks.items(Demo.pullRequests)
    #expect(items.count == 1 && items[0].isStack)
    #expect(items[0].pullRequests.map(\.id) == [Demo.baseID, Demo.mainID])
    #expect(Demo.pullRequests.allSatisfy { $0.isDemo })
    #expect(Demo.pullRequests.filter(\.needsReReview).map(\.id) == [Demo.baseID]) // shows "changed since review"
}

@Test func demoPatchesMatchTheirHunkHeadersAndCoverEveryStatus() throws {
    let files = Demo.files.values.flatMap { $0 }
    #expect(Set(Demo.files[Demo.mainID]!.map(\.status)) == ["added", "removed", "modified"])
    for file in files {
        let patch = try #require(file.patch)
        let lines = Diff.parse(patch)
        let header = try #require(lines.first?.text)
        let counts = header.split(separator: " ").dropFirst().prefix(2).map { $0.split(separator: ",").last.flatMap { Int($0) } ?? 1 }
        #expect(lines.filter { $0.kind != .added && $0.kind != .hunk }.count == counts[0], "old side of \(file.filename)")
        #expect(lines.filter { $0.kind != .removed && $0.kind != .hunk }.count == counts[1], "new side of \(file.filename)")
        #expect(lines.filter { $0.kind == .added }.count == file.additions, "additions of \(file.filename)")
        #expect(lines.filter { $0.kind == .removed }.count == file.deletions, "deletions of \(file.filename)")
    }
}

@Test func demoAnalysisPointsAtRealLinesAndHasAnOutdatedRun() throws {
    let main = try #require(Demo.pullRequests.first { $0.id == Demo.mainID })
    let files = try #require(Demo.files[Demo.mainID])
    let runs = Demo.runs.filter { $0.prID == Demo.mainID }
    let base = try #require(Demo.pullRequests.first { $0.id == Demo.baseID })
    let baseRuns = Demo.runs.filter { $0.prID == Demo.baseID }
    #expect(!baseRuns.isEmpty && baseRuns.allSatisfy { $0.isOutdated(for: base) }) // the stale banner shows on the base PR
    #expect(runs.filter { $0.headRefOid == main.headRefOid }.count == 1)
    #expect(runs.contains { $0.headRefOid != main.headRefOid }) // the outdated state shows too
    let current = try #require(runs.first { $0.headRefOid == main.headRefOid })
    let (inline, general) = AIContext.validate(current.result, files: files)
    #expect(inline.count == current.result.findings.count && general.isEmpty) // every finding anchors in the diff
    #expect(current.result.risks.map(\.question) == RiskQuestion.allCases.map(\.rawValue))
    #expect(current.result.score == 4.5) // a high-risk finding: fix before merging
    let focus = Focus.files(keyAreas: current.result.keyAreas, pendingPaths: Demo.drafts.map(\.anchor.path), changed: files.map(\.filename))
    #expect(focus.map(\.path) == ["app/invites/migrations/0003_invite_sent_at.py", "app/invites/views.py", "app/invites/tasks.py"])
    #expect(Set(current.result.keyAreas.compactMap(\.question)) == [.data, .access, .failure])
    let anchors = Set(files.flatMap { Diff.anchors(path: $0.filename, patch: $0.patch ?? "") })
    #expect(Demo.drafts.allSatisfy { anchors.contains($0.anchor) })
    let notes = try #require(Risk.notes(in: Demo.details[Demo.mainID]?.body ?? ""))
    #expect(notes.unsure.count == 1 && notes.byQuestion[.data]?.isEmpty == false)
}

@Test func organizationsAreSavedWithoutDemoKeys() {
    var org = Organization()
    let folder = org.addFolder("Work")
    let demoStack = Demo.pullRequests[0].itemKey
    org.place(demoStack, in: folder.id)
    org.place("stack:real/repo#3", in: folder.id)
    org.notes["pr:\(Demo.mainID)"] = "demo note"
    org.notes["pr:PR_real"] = "real note"
    org.muted = [demoStack, "pr:PR_real"]
    org.unfollowed = [Demo.mainID, "PR_real"]
    let clean = org.removingDemo()
    #expect(Array(clean.placements.keys) == ["stack:real/repo#3"])
    #expect(clean.notes == ["pr:PR_real": "real note"])
    #expect(clean.muted == ["pr:PR_real"] && clean.unfollowed == ["PR_real"])
    #expect(clean.folders == org.folders)
}

@Test func demoFollowUpMatchesTheViewersThreads() throws {
    let base = try #require(Demo.pullRequests.first { $0.id == Demo.baseID })
    let detail = try #require(Demo.details[Demo.baseID])
    #expect(FollowUp.isDue(base, detail: detail, viewer: Demo.viewer))
    let threads = FollowUp.threads(of: Demo.viewer, in: detail)
    let run = try #require(Demo.followUps.first)
    #expect(Set(run.result.items.compactMap { $0.threadID }) == Set(threads.map { $0.id }))
    let anchors = Set(Demo.files[Demo.baseID]!.flatMap { Diff.anchors(path: $0.filename, patch: $0.patch ?? "") })
    #expect(threads.allSatisfy { anchors.contains(Anchor(path: $0.path, line: $0.line ?? 0, side: $0.side)) })
}

@Test func demoThreadsSitUnderTheirReviewWithDiffContext() throws {
    for detail in Demo.details.values {
        let items = Conversation.timeline(detail, viewer: Demo.viewer, filter: .all)
        #expect(!items.contains { if case .thread = $0 { true } else { false } }) // every thread has its review
        for thread in detail.threads {
            #expect(Conversation.context(thread).last?.newLine == thread.line, "context of \(thread.id)")
        }
    }
}
