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
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(kind: .paragraph, text: AttributedString(source), quoted: false)]
        }

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
