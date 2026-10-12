import ReviewDeskCore
import SwiftUI

/// GitHub-flavoured Markdown: headings, lists, quotes, code blocks, tables and rules.
struct MarkdownText: View {
    let blocks: [MarkdownBlock]

    init(_ source: String) { blocks = Markdown.blocks(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.quoted {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                        content(block).foregroundStyle(.secondary)
                    }
                } else {
                    content(block)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func content(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.text).fixedSize(horizontal: false, vertical: true)
        case .heading(let level):
            Text(block.text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text).font(.system(.callout, design: .monospaced)).padding(10)
            }
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        case .listItem(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).frame(minWidth: 16, alignment: .trailing).foregroundStyle(.secondary)
                Text(block.text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth - 1) * 20)
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .fontWeight(index == 0 ? .semibold : .regular)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .border(.quaternary)
                        }
                    }
                }
            }
        case .rule:
            Divider()
        }
    }
}
