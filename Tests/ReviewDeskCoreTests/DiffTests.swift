import Testing
@testable import ReviewDeskCore

private let patch = """
@@ -10,4 +10,5 @@ func main() {
 let a = 1
-let b = 2
+let b = 3
+let c = 4
 return a
\\ No newline at end of file
@@ -40,2 +41,2 @@
-old
+new
"""

@Test func parsesLineNumbersAcrossHunks() {
    let lines = Diff.parse(patch)
    #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .context, .hunk, .removed, .added])
    #expect(lines[1].oldLine == 10 && lines[1].newLine == 10)
    #expect(lines[2].oldLine == 11 && lines[2].newLine == nil)
    #expect(lines[4].newLine == 12)
    #expect(lines[5].oldLine == 12 && lines[5].newLine == 13)
    #expect(lines[7].oldLine == 40 && lines[8].newLine == 41)
    #expect(lines[3].text == "let b = 3")
}

@Test func anchorsCoverOnlyLinesInHunks() {
    let anchors = Diff.anchors(path: "a.swift", patch: patch)
    #expect(anchors.contains(Anchor(path: "a.swift", line: 12)))
    #expect(anchors.contains(Anchor(path: "a.swift", line: 11, side: .left)))
    #expect(!anchors.contains(Anchor(path: "a.swift", line: 20)))
    #expect(!anchors.contains(Anchor(path: "b.swift", line: 12)))
}

@Test func ignoresTrailingNewline() {
    #expect(Diff.parse("@@ -1 +1 @@\n-a\n+b\n").map(\.kind) == [.hunk, .removed, .added])
}

@Test func sideBySidePairsRemovedWithAddedLines() {
    let rows = Diff.sideBySide(Diff.parse("""
    @@ -1,5 +1,4 @@
     keep
    -a
    -b
    -c
    +x
    +y
     end
    +tail
    """))
    #expect(rows.count == 7)
    #expect(rows[0].hunk != nil)
    #expect(rows[1].left?.text == "keep" && rows[1].right?.text == "keep")
    #expect(rows[2].left?.text == "a" && rows[2].right?.text == "x")
    #expect(rows[3].left?.text == "b" && rows[3].right?.text == "y")
    #expect(rows[4].left?.text == "c" && rows[4].right == nil)
    #expect(rows[5].left?.text == "end")
    #expect(rows[6].left == nil && rows[6].right?.text == "tail")
}

@Test func changeBlocksAreClassifiedAsAWhole() {
    let lines = Diff.parse("""
    @@ -1,6 +1,6 @@
     keep
    -old
    +new
    +extra
     keep
    +only added
     keep
    -only removed
    """)
    #expect(Diff.changes(lines) == [nil, nil, .modified, .modified, .modified, nil, .added, nil, .removed])
    let rows = Diff.sideBySide(lines)
    #expect(rows.map(\.change) == [nil, nil, .modified, .modified, nil, .added, nil, .removed])
}

@Test func keyAreaLinesMapToTheirDiffRows() {
    let lines = Diff.parse(patch)
    let unified = DiffIndex(lines: lines, path: "a.swift")
    // Line 11 is also the removed "let b = 2" (old side): the jump must land on the added line 11.
    #expect(unified.row(ofNewLines: 11...11) == 3)
    #expect(unified.row(ofNewLines: 10...12) == 1)
    #expect(unified.row(ofNewLines: 5...30) == 1) // starts before the hunk: its first line in the diff
    #expect(unified.row(ofNewLines: 20...30) == nil) // unchanged code between hunks: not in this diff
    #expect(unified.row(ofNewLines: 1...9) == nil) // before the first hunk
    #expect(unified.row(ofNewLines: 42...50) == nil) // past the last hunk
    let rows = Diff.sideBySide(lines)
    let split = DiffIndex(rows: rows, path: "a.swift")
    #expect(split.row(ofNewLines: 11...11).flatMap { rows[$0].right?.text } == "let b = 3")
    #expect(split.row(ofNewLines: 30...41).flatMap { rows[$0].right?.text } == "new")
    #expect(split.row(ofNewLines: 20...30) == nil)
}

@Test func keyAreasAboutRemovedCodeFindTheirOldLines() {
    let lines = Diff.parse(patch)
    let unified = DiffIndex(lines: lines, path: "a.swift")
    let removedB = KeyArea(path: "a.swift", startLine: 11, reason: "", side: "old")
    #expect(unified.row(of: removedB) == 2) // the removed "let b = 2", not the added line 11
    #expect(unified.row(of: KeyArea(path: "a.swift", startLine: 11, reason: "")) == 3)
    #expect(unified.row(of: KeyArea(path: "a.swift", startLine: 40, endLine: 41, reason: "", side: "old")) == 7)
    #expect(unified.row(of: KeyArea(path: "a.swift", startLine: 20, endLine: 30, reason: "", side: "old")) == nil)
    #expect(unified.row(of: KeyArea(path: "a.swift", reason: "", side: "old")) == nil) // whole file
    let rows = Diff.sideBySide(lines)
    let split = DiffIndex(rows: rows, path: "a.swift")
    #expect(split.row(of: removedB).flatMap { rows[$0].left?.text } == "let b = 2")
    #expect(split.row(of: KeyArea(path: "a.swift", startLine: 40, reason: "", side: "old")).flatMap { rows[$0].left?.text } == "old")
}

@Test func commentAnchorsMapToTheirDiffRows() {
    let lines = Diff.parse(patch)
    let rows = Diff.sideBySide(lines)
    let unified = DiffIndex(lines: lines, path: "a.swift"), split = DiffIndex(rows: rows, path: "a.swift")
    let removed = Anchor(path: "a.swift", line: 11, side: .left), added = Anchor(path: "a.swift", line: 11)
    #expect(unified.row(of: removed) == 2)
    #expect(unified.row(of: added) == 3)
    // Side by side, the removed and the added line 11 share a row.
    #expect(split.row(of: removed) != nil && split.row(of: removed) == split.row(of: added))
    #expect(split.row(of: Anchor(path: "a.swift", line: 13)).flatMap { rows[$0].right?.text } == "return a")
    #expect(unified.row(of: Anchor(path: "a.swift", line: 30)) == nil) // outdated: no longer in the diff
    #expect(unified.row(of: Anchor(path: "b.swift", line: 11)) == nil) // another file's draft
}
