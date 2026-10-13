import Foundation
import Testing
@testable import ReviewDeskCore

@Test func editorLinksCarryThePathAndLine() {
    let vscode = EditorLink.presets[0].template, idea = EditorLink.presets.first { $0.name == "IntelliJ IDEA" }!.template
    #expect(EditorLink.url(template: vscode, path: "/Users/me/code/r/Sources/a.swift", line: 12)?.absoluteString
        == "vscode://file/Users/me/code/r/Sources/a.swift:12")
    #expect(EditorLink.url(template: idea, path: "/Users/me/My Code/r&d/a#1.py", line: 0)?.absoluteString
        == "idea://open?file=/Users/me/My%20Code/r%26d/a%231.py&line=1")
}

@Test func firstChangeIsTheFirstAddedOrRemovedLine() {
    let patch = """
    @@ -10,4 +10,5 @@ func a() {
     let x = 1
     let y = 2
    -let z = 3
    +let z = 4
    +let w = 5
     }
    """
    #expect(EditorLink.firstChange(in: patch) == 12)
    // A pure deletion points at the line that now follows it, or at the last line when nothing follows.
    #expect(EditorLink.firstChange(in: "@@ -1,3 +1,2 @@\n a\n-b\n c") == 2)
    #expect(EditorLink.firstChange(in: "@@ -1,2 +1,1 @@\n a\n-b") == 1)
    #expect(EditorLink.firstChange(in: "") == 1)
}
