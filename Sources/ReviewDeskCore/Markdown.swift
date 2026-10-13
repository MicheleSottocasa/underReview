import Foundation

/// A rendered-ready block of GitHub Markdown. Inline styles (bold, code, links) stay in `text`.
public struct MarkdownBlock: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case paragraph
        case heading(level: Int)
        case code(language: String?)
        /// `marker` is "•" or "1." on an item's first paragraph and "" on its continuation paragraphs.
        case listItem(marker: String, depth: Int)
        /// First row is the header.
        case table(rows: [[AttributedString]])
        case rule
    }

    public var kind: Kind
    public var text: AttributedString
    /// Inside a `>` block quote.
    public var quoted: Bool
}

public enum Markdown {
    /// Splits Markdown into blocks using Foundation's parser; falls back to one plain paragraph.
    /// Commit SHAs and PR references become links (see `linkify`); `repo` is the PR's own, for `#123` and bare SHAs.
    public static func blocks(_ source: String, repo: String? = nil) -> [MarkdownBlock] {
        let source = cleanHTML(source)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let markdown = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(kind: .paragraph, text: AttributedString(source), quoted: false)]
        }
        let parsed = linkify(markdown, repo: repo)

        var blocks: [MarkdownBlock] = []
        var currentKey: Int?
        var seenListItems = Set<Int>()
        var table: (id: Int, rows: [Int: [AttributedString]], order: [Int])?

        func flushTable() {
            guard let done = table else { return }
            blocks.append(MarkdownBlock(kind: .table(rows: done.order.map { done.rows[$0] ?? [] }), text: AttributedString(), quoted: false))
            table = nil
        }

        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let text = AttributedString(parsed[run.range])
            let quoted = components.contains { if case .blockQuote = $0.kind { true } else { false } }

            if let tableComponent = components.first(where: { if case .table = $0.kind { true } else { false } }) {
                if table?.id != tableComponent.identity {
                    flushTable()
                    table = (tableComponent.identity, [:], [])
                }
                let row = components.first { if case .tableRow = $0.kind { true } else if case .tableHeaderRow = $0.kind { true } else { false } }
                guard let rowID = row?.identity, case .tableCell(let column)? = components.first?.kind else { continue }
                if table!.rows[rowID] == nil { table!.order.append(rowID) }
                var cells = table!.rows[rowID] ?? []
                while cells.count <= column { cells.append(AttributedString()) }
                cells[column].append(text)
                table!.rows[rowID] = cells
                currentKey = nil
                continue
            }
            flushTable()

            guard let innermost = components.first else {
                appendOrStart(&blocks, key: -1, current: &currentKey, kind: .paragraph, text: text, quoted: false)
                continue
            }
            let kind: MarkdownBlock.Kind
            switch innermost.kind {
            case .header(let level):
                kind = .heading(level: level)
            case .codeBlock(let language):
                kind = .code(language: language)
            case .thematicBreak:
                kind = .rule
            default:
                if let item = components.first(where: { if case .listItem = $0.kind { true } else { false } }),
                   case .listItem(let ordinal) = item.kind {
                    let lists = components.filter {
                        switch $0.kind {
                        case .orderedList, .unorderedList: true
                        default: false
                        }
                    }
                    let ordered = lists.first.map { if case .orderedList = $0.kind { true } else { false } } ?? false
                    let isFirst = currentKey != innermost.identity && seenListItems.insert(item.identity).inserted
                    let marker = isFirst ? (ordered ? "\(ordinal)." : "•") : ""
                    kind = .listItem(marker: marker, depth: lists.count)
                } else {
                    kind = .paragraph
                }
            }
            appendOrStart(&blocks, key: innermost.identity, current: &currentKey, kind: kind, text: text, quoted: quoted)
        }
        flushTable()

        return blocks.map { block in
            guard case .code = block.kind else { return block }
            var trimmed = block
            while trimmed.text.characters.last == "\n" { trimmed.text.characters.removeLast() }
            return trimmed
        }
    }

    /// GitHub's autolinks, outside code: commit SHAs (7 to 40 hex characters with a letter and a digit), `#123`,
    /// `GH-123`, `owner/repo#123`, `owner/repo@sha`, and GitHub URLs to PRs, issues and commits, shown short.
    /// Links point at github.com; the app opens the PRs it follows itself. Without `repo`, `#123`, `GH-123` and
    /// bare SHAs stay text.
    public static func linkify(_ text: AttributedString, repo: String?) -> AttributedString {
        let pattern = try! NSRegularExpression(pattern: [
            #"https://github\.com/[\w.-]+/[\w.-]+/(?:pull|issues|commit)/\w+"#,
            #"(?<![\w./-])[\w.-]+/[\w.-]+(?:#\d+|@[0-9a-f]{7,40})\b"#,
            #"(?<![\w&#/])(?:#|GH-)\d+\b"#,
            #"(?<![\w#/@.-])[0-9a-f]{7,40}(?![\w-])"#,
        ].joined(separator: "|"))
        var result = AttributedString()
        for run in text.runs {
            let piece = AttributedString(text[run.range])
            let string = String(piece.characters)
            let inCode = run.inlinePresentationIntent?.contains(.code) == true
                || run.presentationIntent?.components.contains { if case .codeBlock = $0.kind { true } else { false } } == true
            if inCode {
                result.append(piece)
            } else if let link = run.link {
                // A bare URL shows short, as on GitHub; a written link keeps its text.
                if string == link.absoluteString, let short = autolink(string, repo: repo)?.title {
                    result.append(AttributedString(short, attributes: run.attributes))
                } else {
                    result.append(piece)
                }
            } else {
                var rest = string.startIndex
                for match in pattern.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
                    guard let range = Range(match.range, in: string), let target = autolink(String(string[range]), repo: repo) else { continue }
                    result.append(AttributedString(String(string[rest..<range.lowerBound]), attributes: run.attributes))
                    var linked = AttributedString(target.title, attributes: run.attributes)
                    linked.link = target.url
                    result.append(linked)
                    rest = range.upperBound
                }
                result.append(AttributedString(String(string[rest...]), attributes: run.attributes))
            }
        }
        return result
    }

    /// Whether a link from Markdown (untrusted: anyone can comment) may be handed to the system: web and mail
    /// links only, never `file://` or another app's URL scheme.
    public static func opensOutside(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    /// What a reference shows and where it points, or nil when it isn't one (e.g. a hex word without digits).
    static func autolink(_ text: String, repo: String?) -> (title: String, url: URL)? {
        func isSHA(_ word: Substring) -> Bool {
            (7...40).contains(word.count) && word.allSatisfy(\.isHexDigit) && word.contains(where: \.isLetter) && word.contains(where: \.isNumber)
        }
        func link(_ title: String, _ name: String, _ kind: String, _ id: Substring) -> (title: String, url: URL)? {
            URL(string: "https://github.com/\(name)/\(kind)/\(id)").map { (title, $0) }
        }
        let github = "https://github.com/"
        if text.hasPrefix(github) {
            let parts = text.dropFirst(github.count).split(separator: "/")
            guard parts.count >= 4, let url = URL(string: text) else { return nil }
            let name = "\(parts[0])/\(parts[1])", id = parts[3].prefix { $0.isLetter || $0.isNumber }
            switch parts[2] {
            case "pull", "issues": return Int(id) == nil ? nil : ("\(name)#\(id)", url)
            case "commit": return isSHA(id) ? (String(id.prefix(7)), url) : nil
            default: return nil
            }
        }
        if let at = text.firstIndex(of: "@") {
            let sha = text[text.index(after: at)...], name = String(text[..<at])
            return isSHA(sha) ? link("\(name)@\(sha.prefix(7))", name, "commit", sha) : nil
        }
        if let hash = text.firstIndex(of: "#"), hash != text.startIndex {
            return link(text, String(text[..<hash]), "pull", text[text.index(after: hash)...])
        }
        guard let repo else { return nil }
        if text.hasPrefix("#") || text.hasPrefix("GH-") {
            return link(text, repo, "pull", text.drop { !$0.isNumber })
        }
        return isSHA(text[...]) ? link(String(text.prefix(7)), repo, "commit", text[...]) : nil
    }

    /// GitHub renders inline HTML and hides comments; Foundation's parser shows them raw. Bots (e.g. review
    /// tools) embed both. Comments are dropped, images become their alt text, links become Markdown links and
    /// other common tags are removed, outside fenced code blocks only.
    public static func cleanHTML(_ source: String) -> String {
        var inFence = false
        var prose: [String] = [], output: [String] = []
        func flush() {
            if !prose.isEmpty { output.append(cleanProse(prose.joined(separator: "\n"))) }
            prose = []
        }
        for line in source.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !inFence { flush() }
                inFence.toggle()
                output.append(line)
            } else if inFence {
                output.append(line)
            } else {
                prose.append(line)
            }
        }
        flush()
        return output.joined(separator: "\n")
    }

    private static func cleanProse(_ text: String) -> String {
        var text = text
        func replace(_ pattern: String, with template: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        replace("<!--.*?-->", with: "")
        replace(#"<img\b[^>]*\balt="([^"]*)"[^>]*>"#, with: "$1")
        replace(#"<br\s*/?>"#, with: "  \n")
        replace(#"<a\b[^>]*\bhref="([^"]*)"[^>]*>(.*?)</a>"#, with: "[$2]($1)")
        replace(#"</?(?:a|img|picture|source|div|span|p|details|summary|sub|sup|b|i|strong|em|kbd|code|h[1-6])\b[^>]*>"#, with: "")
        replace(#"\[\s*\]\(([^)]*)\)"#, with: "[link]($1)")
        replace(#"\n{3,}"#, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendOrStart(_ blocks: inout [MarkdownBlock], key: Int, current: inout Int?, kind: MarkdownBlock.Kind,
                                      text: AttributedString, quoted: Bool) {
        if current == key, !blocks.isEmpty {
            blocks[blocks.count - 1].text.append(text)
        } else {
            blocks.append(MarkdownBlock(kind: kind, text: text, quoted: quoted))
            current = key
        }
    }
}
