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

private func links(_ markdown: String, repo: String? = "o/r") -> [String] {
    Markdown.blocks(markdown, repo: repo).flatMap { block in
        block.text.runs.compactMap { run in run.link.map { "\(String(block.text[run.range].characters)) -> \($0.absoluteString)" } }
    }
}

@Test func linksCommitsAndPullRequestsLikeGitHub() {
    #expect(links("Fixed in a1b2c3d, see #12, GH-13, octo/cat#14 and octo/cat@a1b2c3d4e5.") == [
        "a1b2c3d -> https://github.com/o/r/commit/a1b2c3d",
        "#12 -> https://github.com/o/r/pull/12",
        "GH-13 -> https://github.com/o/r/pull/13",
        "octo/cat#14 -> https://github.com/octo/cat/pull/14",
        "octo/cat@a1b2c3d -> https://github.com/octo/cat/commit/a1b2c3d4e5",
    ])
    let full = "0123456789abcdef0123456789abcdef01234567"
    #expect(links("Head is \(full).") == ["0123456 -> https://github.com/o/r/commit/\(full)"])
}

@Test func linksGitHubURLsShortButKeepsWrittenLinkText() {
    #expect(links("See <https://github.com/octo/cat/pull/7>, <https://github.com/octo/cat/commit/a1b2c3d4e5f6> and [the fix](https://github.com/octo/cat/pull/8).") == [
        "octo/cat#7 -> https://github.com/octo/cat/pull/7",
        "a1b2c3d -> https://github.com/octo/cat/commit/a1b2c3d4e5f6",
        "the fix -> https://github.com/octo/cat/pull/8",
    ])
    #expect(links("Bare https://github.com/octo/cat/issues/9 too.") == ["octo/cat#9 -> https://github.com/octo/cat/issues/9"])
}

@Test func onlyWebAndMailLinksLeaveTheApp() {
    for safe in ["https://github.com/o/r/pull/1", "HTTP://example.com", "mailto:a@b.c"] {
        #expect(Markdown.opensOutside(URL(string: safe)!), "\(safe)")
    }
    for unsafe in ["file:///etc/passwd", "x-apple.systempreferences:com.apple.preference", "vscode://file/a", "javascript:alert(1)"] {
        #expect(!Markdown.opensOutside(URL(string: unsafe)!), "\(unsafe)")
    }
}

@Test func leavesCodeAndLookalikesAlone() {
    #expect(links("`a1b2c3d` and `#12`\n\n```\nfix a1b2c3d, #12\n```").isEmpty)
    // No digit, no letter, a color, a UUID, a file path with an anchor, an HTML entity.
    #expect(links("deadbeef 1234567 #a1b2c3 #a1b2c3d4 123e4567-e89b-12d3-a456-426614174000 src/app/main.py#12 &#123;").isEmpty)
    // `#12` and bare SHAs need the PR's repo; references to other repos don't.
    #expect(links("#12 a1b2c3d octo/cat#14", repo: nil) == ["octo/cat#14 -> https://github.com/octo/cat/pull/14"])
}
