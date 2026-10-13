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

@Test func readKeysNameTheFileLinesAndRisk() {
    #expect(KeyArea(path: "a.swift", startLine: 3, endLine: 9, reason: "x").readKey == "a.swift:3-9:")
    #expect(KeyArea(path: "a.swift", startLine: 3, endLine: 9, reason: "reworded").readKey == "a.swift:3-9:")
    #expect(KeyArea(path: "a.swift", startLine: 3, endLine: 9, reason: "x", risk: "data").readKey == "a.swift:3-9:data")
    #expect(KeyArea(path: "a.swift", reason: "x").readKey == "a.swift:file-:")
}

@Test func readMarksDropOlderHeads() {
    let marks = ["a:1-2:": "old", "b:3-4:": "new"]
    #expect(Focus.readMarks(marks, setting: "c:5-6:", read: true, head: "new") == ["b:3-4:": "new", "c:5-6:": "new"])
    #expect(Focus.readMarks(marks, setting: "b:3-4:", read: false, head: "new") == [:])
    #expect(Focus.readMarks(marks, setting: "a:1-2:", read: true, head: "newer") == ["a:1-2:": "newer"])
}

@Test func keyAreaRangesCoverTheirLinesOnly() {
    #expect(KeyArea(path: "a", startLine: 10, endLine: 12, reason: "").contains(line: 12))
    #expect(!KeyArea(path: "a", startLine: 10, endLine: 12, reason: "").contains(line: 13))
    #expect(KeyArea(path: "a", startLine: 7, reason: "").contains(line: 7))
    #expect(!KeyArea(path: "a", reason: "").contains(line: 1)) // whole-file areas don't tint every line
}
