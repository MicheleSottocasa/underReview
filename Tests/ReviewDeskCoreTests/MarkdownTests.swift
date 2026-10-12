import Foundation
import Testing
@testable import ReviewDeskCore

private func plain(_ block: MarkdownBlock) -> String { String(block.text.characters) }

@Test func splitsHeadingsParagraphsAndCode() {
    let blocks = Markdown.blocks("""
    ### MFA docs omit **freshness**

    Para with `code`.

    ```swift
    let x = 1
    ```
    """)
    #expect(blocks.map(\.kind) == [.heading(level: 3), .paragraph, .code(language: "swift")])
    #expect(plain(blocks[0]) == "MFA docs omit freshness")
    #expect(plain(blocks[2]) == "let x = 1")
    #expect(blocks[0].text.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
}

@Test func listsCarryMarkersAndDepth() {
    let blocks = Markdown.blocks("""
    - one
    - two
      1. nested
    """)
    #expect(blocks.map(\.kind) == [
        .listItem(marker: "•", depth: 1),
        .listItem(marker: "•", depth: 1),
        .listItem(marker: "1.", depth: 2),
    ])
    #expect(blocks.map(plain) == ["one", "two", "nested"])
}

@Test func quotesTablesAndRules() {
    let blocks = Markdown.blocks("""
    > careful

    | a | b |
    |---|---|
    | 1 | 2 |

    ---
    """)
    #expect(blocks.count == 3)
    #expect(blocks[0].quoted && plain(blocks[0]) == "careful")
    guard case .table(let rows) = blocks[1].kind else { Issue.record("expected table"); return }
    #expect(rows.map { $0.map { String($0.characters) } } == [["a", "b"], ["1", "2"]])
    #expect(blocks[2].kind == .rule)
}

@Test func plainTextIsOneParagraph() {
    #expect(Markdown.blocks("just text").map(plain) == ["just text"])
    #expect(Markdown.blocks("").isEmpty)
}

@Test func htmlCommentsAndTagsAreCleanedLikeGitHub() {
    let bot = """
    ### MFA docs omit freshness requirement

    <!-- DESCRIPTION START -->
    The page is stale.
    <!-- DESCRIPTION END -->
    <!-- LOCATIONS START
    a.py#L73-L78
    LOCATIONS END -->
    <div><a href="https://cursor.com/open?x=1" target="_blank"><picture><source media="(prefers-color-scheme: dark)" srcset="d.png"><img alt="Fix in Cursor" src="l.png"></picture></a></div>
    """
    #expect(Markdown.cleanHTML(bot) == """
    ### MFA docs omit freshness requirement

    The page is stale.

    [Fix in Cursor](https://cursor.com/open?x=1)
    """)
    #expect(Markdown.blocks(bot).map { String($0.text.characters) } == ["MFA docs omit freshness requirement", "The page is stale.", "Fix in Cursor"])
}

@Test func htmlInsideCodeFencesIsKept() {
    let source = "```swift\nlet a: Array<Int> = [] // <!-- not a comment -->\n```\n<b>bold</b>"
    #expect(Markdown.cleanHTML(source) == "```swift\nlet a: Array<Int> = [] // <!-- not a comment -->\n```\nbold")
}
