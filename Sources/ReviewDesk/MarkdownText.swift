import ReviewDeskCore
import SwiftUI

/// GitHub-flavoured Markdown: headings, lists, quotes, code blocks, tables and rules.
struct MarkdownText: View {
    let source: String
    @Environment(\.markdownRepo) private var repo

    init(_ source: String) { self.source = source }

    var body: some View {
        let blocks = Markdown.blocks(source, repo: repo)
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
            Text(Self.styled(block.text)).fixedSize(horizontal: false, vertical: true)
        case .heading(let level):
            Text(Self.styled(block.text))
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
                Text(Self.styled(block.text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth - 1) * 20)
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.styled(cell))
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

    /// `inline code` as a GitHub-style chip: monospaced on a tinted background.
    static func styled(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(.callout, design: .monospaced)
            text[run.range].backgroundColor = Color.secondary.opacity(0.18)
        }
        return text
    }
}

/// One line of AI text (a rationale, a reason) with its `code` and **bold** rendered, for places too small for blocks.
func inlineMarkdown(_ text: String, repo: String?) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return MarkdownText.styled(Markdown.linkify((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text), repo: repo))
}

private struct MarkdownRepoKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The PR's repo, so Markdown can link `#123` and commit SHAs to it.
    var markdownRepo: String? {
        get { self[MarkdownRepoKey.self] }
        set { self[MarkdownRepoKey.self] = newValue }
    }
}

/// Opens the PRs the app follows in the app, and other links (other PRs, commits) in the browser.
/// The demo never opens GitHub. Comments are untrusted: only web and mail links leave the app, never `file://`
/// or another app's scheme.
struct LinkHandler: ViewModifier {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    func body(content: Content) -> some View {
        content
            .environment(\.markdownRepo, pr.repo)
            .environment(\.openURL, OpenURLAction { url in
                guard Markdown.opensOutside(url) else { return .discarded }
                let ref = PRRef(url.absoluteString)
                if let ref, let target = model.prs.values.first(where: { $0.repo.lowercased() == ref.nameWithOwner.lowercased() && $0.number == ref.number }) {
                    model.selection = [.pr(target.id)]
                    return .handled
                }
                return model.blockDemo(pr) ? .handled : .systemAction
            })
    }
}
