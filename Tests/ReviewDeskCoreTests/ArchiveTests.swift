import Foundation
import Testing
@testable import ReviewDeskCore

private let now = Date(timeIntervalSince1970: 10 * 86_400)

private func pr(_ id: String, _ number: Int, state: String = "OPEN", head: String = "h1", requested: [String] = [],
                stack: Int? = nil, entries: [String] = []) -> PullRequest {
    var pr = PullRequest(
        id: id, number: number, title: "", url: "", state: state, isDraft: false, updatedAt: now, headRefOid: head,
        headRefName: "", baseRefName: "", author: "", repo: "o/r", commentCount: 0, reviewCount: 0, threadCommentCount: 0,
        requestedReviewers: requested,
        stack: stack.map { StackInfo(number: $0, entries: entries.enumerated().map { .init(position: $0 + 1, id: $1, number: 0) }) })
    if state != "OPEN" { pr.closedAt = now.addingTimeInterval(-3 * 86_400) }
    return pr
}

private func item(_ prs: PullRequest...) -> Item { Stacks.items(prs)[0] }

private func keys(_ archive: PRArchive, _ prs: [PullRequest], afterDays: Int = 1) -> Set<String> {
    archive.itemKeys(prs, now: now, afterDays: afterDays) { _ in "me" }
}

@Test func archivedByHandUntilANewPushOrReviewRequest() {
    var archive = PRArchive()
    let open = pr("A", 1), asked = pr("B", 2, requested: ["me"])
    archive.archive(item(open)) { _ in "me" }
    archive.archive(item(asked)) { _ in "me" }
    #expect(keys(archive, [open, asked]) == ["pr:A", "pr:B"])
    // Still asked for the same review: stays archived.
    #expect(keys(archive, [pr("A", 1), pr("B", 2, requested: ["me"])]) == ["pr:A", "pr:B"])

    let pushed = pr("A", 1, head: "h2")
    #expect(keys(archive, [pushed, asked]) == ["pr:B"])
    archive.update([pushed, asked]) { _ in "me" }
    #expect(archive.manual["pr:A"] == nil)
    // The mark is gone: pushing back to the archived head doesn't archive it again.
    #expect(keys(archive, [open, asked]) == ["pr:B"])
}

@Test func aReviewRequestThatEndedAndCameBackWakesTheItem() {
    var archive = PRArchive()
    archive.archive(item(pr("B", 2, requested: ["me"]))) { _ in "me" }
    archive.update([pr("B", 2)]) { _ in "me" } // reviewed: the request ended
    #expect(archive.manual["pr:B"]?.requested == [])
    #expect(keys(archive, [pr("B", 2, requested: ["me"])]).isEmpty)
    // Someone else being asked isn't a request for the viewer.
    var other = PRArchive()
    other.archive(item(pr("C", 3))) { _ in "me" }
    #expect(keys(other, [pr("C", 3, requested: ["bob"])]) == ["pr:C"])
}

@Test func aStackWakesWhenAnyOpenMemberMovesOrJoins() {
    var archive = PRArchive()
    let entries = ["A", "B"]
    let stack = [pr("A", 1, state: "MERGED", stack: 1, entries: entries), pr("B", 2, stack: 1, entries: entries)]
    archive.archive(item(stack[0], stack[1])) { _ in "me" }
    #expect(keys(archive, stack) == ["stack:o/r#1"])
    let joined = stack + [pr("C", 3, stack: 1, entries: entries + ["C"])]
    #expect(keys(archive, joined).isEmpty)
    // Merged members never wake it, whatever their head.
    var merged = PRArchive()
    let done = pr("D", 4, state: "MERGED")
    merged.archive(item(done)) { _ in "me" }
    #expect(keys(merged, [pr("D", 4, state: "MERGED", head: "other")], afterDays: 0) == ["pr:D"])
}

@Test func unarchivingAnAgedItemKeepsItOutUntilArchivedAgain() {
    var archive = PRArchive()
    let merged = pr("M", 1, state: "MERGED"), open = pr("O", 2)
    #expect(keys(archive, [merged, open]) == ["pr:M"])
    archive.unarchive(item(merged), now: now, afterDays: 1)
    archive.unarchive(item(open), now: now, afterDays: 1)
    #expect(archive.kept == ["pr:M"]) // an open item has nothing to keep out of
    #expect(keys(archive, [merged, open]).isEmpty)
    archive.archive(item(merged)) { _ in "me" }
    #expect(archive.kept.isEmpty && keys(archive, [merged]) == ["pr:M"])
    archive.forget(["pr:M"])
    #expect(archive == PRArchive())
}

@Test func archiveRoundTripsWithoutTheDemo() throws {
    let file = JSONFile<PRArchive>(FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID()).json"))
    defer { try? FileManager.default.removeItem(at: file.url) }
    var archive = PRArchive()
    archive.archive(item(pr("A", 1, requested: ["me"]))) { _ in "me" }
    archive.kept = ["pr:B", "pr:\(Demo.idPrefix)1"]
    archive.manual["pr:\(Demo.idPrefix)2"] = PRArchive.Mark(heads: [:], requested: [])
    try file.save(archive.removingDemo())
    let loaded = file.load(default: PRArchive())
    #expect(loaded.kept == ["pr:B"])
    #expect(loaded.manual == ["pr:A": PRArchive.Mark(heads: ["A": "h1"], requested: ["A"])])
}
