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

@Test func editorLinksNeverOpenTheFileItself() {
    // These would hand the file to its default app: a PR's `.command` would run.
    for template in ["file://{path}", "FILE://{path}", "file:{path}", "{path}"] {
        #expect(EditorLink.url(template: template, path: "/Users/me/code/r/run.command", line: 1) == nil)
    }
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

@Test func onlyRegularFilesInsideTheCloneOpen() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: base) }
    let clone = base.appendingPathComponent("clone"), outside = base.appendingPathComponent("outside.txt")
    try fm.createDirectory(at: clone.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: clone.appendingPathComponent("a.swift"))
    try Data("x".utf8).write(to: outside)
    try fm.createSymbolicLink(atPath: clone.appendingPathComponent("inside-link").path, withDestinationPath: "a.swift")
    try fm.createSymbolicLink(atPath: clone.appendingPathComponent("escape").path, withDestinationPath: outside.path)
    try fm.createSymbolicLink(atPath: clone.appendingPathComponent("launcher").path, withDestinationPath: "Tool.app")
    try fm.createSymbolicLink(atPath: clone.appendingPathComponent("system-app").path, withDestinationPath: "/System/Applications/Calculator.app")

    #expect(try EditorLink.file("a.swift", inClone: clone).lastPathComponent == "a.swift")
    #expect(try EditorLink.file("inside-link", inClone: clone).lastPathComponent == "a.swift")
    #expect(throws: EditorLink.Refusal.missing("gone.swift")) { try EditorLink.file("gone.swift", inClone: clone) }
    #expect(throws: EditorLink.Refusal.outsideClone("escape")) { try EditorLink.file("escape", inClone: clone) }
    #expect(throws: EditorLink.Refusal.outsideClone("system-app")) { try EditorLink.file("system-app", inClone: clone) }
    #expect(throws: EditorLink.Refusal.notAFile("launcher")) { try EditorLink.file("launcher", inClone: clone) }
    #expect(throws: EditorLink.Refusal.notAFile("Tool.app")) { try EditorLink.file("Tool.app", inClone: clone) }
}
