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
