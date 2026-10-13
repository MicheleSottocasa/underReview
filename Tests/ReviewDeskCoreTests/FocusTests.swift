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

@Test func keyAreaRangesCoverTheirLinesOnly() {
    #expect(KeyArea(path: "a", startLine: 10, endLine: 12, reason: "").contains(line: 12))
    #expect(!KeyArea(path: "a", startLine: 10, endLine: 12, reason: "").contains(line: 13))
    #expect(KeyArea(path: "a", startLine: 7, reason: "").contains(line: 7))
    #expect(!KeyArea(path: "a", reason: "").contains(line: 1)) // whole-file areas don't tint every line
}
