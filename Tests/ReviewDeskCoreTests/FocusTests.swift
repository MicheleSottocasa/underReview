import Foundation
import Testing
@testable import ReviewDeskCore

@Test func focusListsKeyFilesFirstThenPendingCommentFiles() {
    let areas = [KeyArea(path: "b.swift", startLine: 10, endLine: 20, reason: "auth"),
                 KeyArea(path: "gone.swift", reason: "not in the PR"),
                 KeyArea(path: "a.swift", reason: "whole file"),
                 KeyArea(path: "b.swift", startLine: 40, reason: "cache")]
    let focus = Focus.files(keyAreas: areas, pendingPaths: ["c.swift", "a.swift", "c.swift"], changed: ["a.swift", "b.swift", "c.swift", "d.swift"])
    #expect(focus.map(\.path) == ["b.swift", "a.swift", "c.swift"])
    #expect(focus[0].areas.count == 2)
    #expect(focus[1].pendingComments == 1)
    #expect(focus[2] == FocusFile(path: "c.swift", areas: [], pendingComments: 2))
}

@Test func nextUnreadFollowsReadingOrderAndWrapsAround() {
    let a1 = KeyArea(path: "a", startLine: 1, reason: ""), a2 = KeyArea(path: "a", startLine: 9, reason: "")
    let b1 = KeyArea(path: "b", reason: "whole file")
    let files = [FocusFile(path: "a", areas: [a1, a2], pendingComments: 0), FocusFile(path: "b", areas: [b1], pendingComments: 0),
                 FocusFile(path: "c", areas: [], pendingComments: 2)]
    func next(read: [KeyArea], after current: (String, Int)?) -> String? {
        Focus.nextUnread(files, isRead: { area in read.contains(area) }, after: current).map { "\($0.path)#\($0.index)" }
    }
    #expect(next(read: [], after: nil) == "a#0")
    #expect(next(read: [], after: ("a", 0)) == "a#1")
    #expect(next(read: [a2], after: ("a", 0)) == "b#0") // skips read areas, across files
    #expect(next(read: [a2], after: ("b", 0)) == "a#0") // wraps around
    #expect(next(read: [a1, a2], after: ("b", 0)) == "b#0") // the current one, when it's the only unread
    #expect(next(read: [a1, a2, b1], after: nil) == nil)
    #expect(next(read: [], after: ("gone", 3)) == "a#0")
}

@Test func steppingPastAFilesAreasContinuesInTheNextFileWithAreas() {
    let area = KeyArea(path: "", reason: "")
    let files = [FocusFile(path: "a", areas: [area, area], pendingComments: 0), FocusFile(path: "b", areas: [], pendingComments: 1),
                 FocusFile(path: "c", areas: [area, area, area], pendingComments: 0)]
    func step(_ path: String, forward: Bool) -> String? {
        Focus.area(beyond: path, in: files, forward: forward).map { "\($0.path)#\($0.index)" }
    }
    #expect(step("a", forward: true) == "c#0") // skips b, which has only comments
    #expect(step("c", forward: false) == "a#1") // lands on the previous file's last area
    #expect(step("b", forward: false) == "a#1")
    #expect(step("c", forward: true) == nil) // no wrapping, like the other steppers
    #expect(step("a", forward: false) == nil)
    #expect(step("elsewhere", forward: true) == "a#0") // a file outside the list starts at either end
    #expect(step("elsewhere", forward: false) == "c#2")
}

@Test func readingListFollowsTheFocusListAndIndexesAreasWithinTheirFile() {
    let a1 = KeyArea(path: "a", startLine: 1, reason: "", risk: "scale"), a2 = KeyArea(path: "a", startLine: 9, reason: "", risk: "data")
    let b1 = KeyArea(path: "b", reason: "whole file", risk: "data")
    let files = [FocusFile(path: "a", areas: [a1, a2], pendingComments: 0), FocusFile(path: "c", areas: [], pendingComments: 2),
                 FocusFile(path: "b", areas: [b1], pendingComments: 0)]
    let list = Focus.readingList(files)
    #expect(list.map { "\($0.path)#\($0.index)" } == ["a#0", "a#1", "b#0"])
    // Risk groups the same list by question, so its areas keep their reading positions.
    #expect(list.indices.filter { list[$0].area.question == .data } == [1, 2])
}

@Test func readKeysNameTheFileLinesAndRisk() {
    #expect(KeyArea(path: "a.swift", startLine: 3, endLine: 9, reason: "x").readKey == "a.swift:3-9:")
    #expect(KeyArea(path: "a.swift", startLine: 3, endLine: 9, reason: "reworded").readKey == "a.swift:3-9:")
    #expect(KeyArea(path: "a.swift", startLine: 3, endLine: 9, reason: "x", risk: "data").readKey == "a.swift:3-9:data")
    #expect(KeyArea(path: "a.swift", reason: "x").readKey == "a.swift:file-:")
    // Old-side areas get their own key; new-side ones keep the key saved before sides existed.
    #expect(KeyArea(path: "a.swift", startLine: 3, endLine: 9, reason: "x", side: "old").readKey == "a.swift:3-9::old")
    #expect(KeyArea(path: "a.swift", startLine: 3, endLine: 9, reason: "x", side: "new").readKey == "a.swift:3-9:")
}

@Test func readMarksDropOlderHeads() {
    let marks = ["a:1-2:": "old", "b:3-4:": "new"]
    #expect(Focus.readMarks(marks, setting: "c:5-6:", read: true, head: "new") == ["b:3-4:": "new", "c:5-6:": "new"])
    #expect(Focus.readMarks(marks, setting: "b:3-4:", read: false, head: "new") == [:])
    #expect(Focus.readMarks(marks, setting: "a:1-2:", read: true, head: "newer") == ["a:1-2:": "newer"])
}

@Test func aFileIsMarkedViewedOnlyOnceAllItsAreasAreRead() {
    let a1 = KeyArea(path: "a", startLine: 1, reason: ""), a2 = KeyArea(path: "a", startLine: 9, reason: "")
    let c = KeyArea(path: "c", reason: "not in the list")
    let files = [FocusFile(path: "a", areas: [a1, a2], pendingComments: 0), FocusFile(path: "b", areas: [], pendingComments: 1)]
    func file(after area: KeyArea, read: [KeyArea], viewed: Set<String> = []) -> String? {
        Focus.fileToMarkViewed(after: area, in: files, viewed: viewed, isRead: read.contains)
    }
    #expect(file(after: a1, read: [a1]) == nil) // a2 is still unread
    #expect(file(after: a2, read: [a1, a2]) == "a")
    #expect(file(after: a2, read: [a1, a2], viewed: ["a"]) == nil) // already Viewed: nothing to write
    #expect(file(after: c, read: [c]) == nil)
}

@Test func keyAreaRangesCoverTheirLinesOnly() {
    #expect(KeyArea(path: "a", startLine: 10, endLine: 12, reason: "").contains(line: 12))
    #expect(!KeyArea(path: "a", startLine: 10, endLine: 12, reason: "").contains(line: 13))
    #expect(KeyArea(path: "a", startLine: 7, reason: "").contains(line: 7))
    #expect(!KeyArea(path: "a", reason: "").contains(line: 1)) // whole-file areas don't tint every line
}

@Test func keyAreasCoverDiffLinesOnTheirSide() {
    let removed = DiffLine(kind: .removed, text: "check()", oldLine: 11)
    let added = DiffLine(kind: .added, text: "x", newLine: 11)
    let context = DiffLine(kind: .context, text: "y", oldLine: 12, newLine: 13)
    let new = KeyArea(path: "a", startLine: 11, endLine: 12, reason: "")
    let old = KeyArea(path: "a", startLine: 11, endLine: 12, reason: "", side: "old")
    #expect(new.covers(added) && !new.covers(removed) && !new.covers(context)) // context is new line 13
    #expect(old.covers(removed) && !old.covers(added) && old.covers(context)) // context is old line 12
    #expect(!old.covers(DiffLine(kind: .hunk, text: "@@")))
    #expect(!KeyArea(path: "a", reason: "", side: "old").covers(removed)) // whole file
    #expect(!KeyArea(path: "a", startLine: 11, reason: "", side: "sideways").isOld) // unknown sides read as new
}

@Test func keyAreasSavedBeforeSidesDecodeAsNewSide() throws {
    let saved = try JSONDecoder().decode(KeyArea.self, from: Data(#"{"path":"a","startLine":3,"endLine":4,"reason":"r","risk":"data"}"#.utf8))
    #expect(saved.side == nil && !saved.isOld)
    let old = try JSONDecoder().decode(KeyArea.self, from: Data(#"{"path":"a","startLine":3,"endLine":null,"reason":"r","risk":"data","side":"old"}"#.utf8))
    #expect(old.isOld)
}

@Test func focusedDiffFoldsTheHunksWithoutKeyAreasOrComments() {
    // Four hunks: rows 0-2, 3-5, 6-8, 9-10 (headers at 0, 3, 6, 9).
    let headers: Set = [0, 3, 6, 9]
    func folds(keeping kept: Set<Int>) -> [Range<Int>] {
        Focus.folds(rows: 11, isHunk: headers.contains, keeps: kept.contains)
    }
    #expect(folds(keeping: [4]) == [0..<3, 6..<11]) // the hunks after the kept one fold as one run
    #expect(folds(keeping: [1, 10]) == [3..<9])
    #expect(folds(keeping: [1, 4, 7, 10]) == [])
    #expect(folds(keeping: []) == []) // nothing kept: the file shows in full rather than vanish
    #expect(Focus.folds(rows: 4, isHunk: { $0 == 2 }, keeps: { $0 == 3 }) == [0..<2]) // rows before the first header
    #expect(Focus.folds(rows: 0, isHunk: { _ in true }, keeps: { _ in true }) == [])
}
