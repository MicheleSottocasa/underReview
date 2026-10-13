import AppKit
import ReviewDeskCore
import SwiftUI

/// A diff line's code. ⌘-click on a name shows its definition; holding ⌘ while moving over the line underlines
/// the names that can be clicked. Plain clicks and text selection work as usual.
struct SymbolText: View {
    let pr: PullRequest
    let path: String
    let line: String
    let text: AttributedString
    let wrap: Bool
    @ViewState private var hovered: Range<Int>?
    @ViewState private var symbol: Symbol?
    @ViewState private var width: CGFloat = 0

    private struct Symbol: Identifiable {
        let name: String
        var id: String { name }
    }

    var body: some View {
        Text(underlined)
            .lineLimit(wrap ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onContinuousHover { phase in
                var range: Range<Int>?
                if case .active(let point) = phase, NSEvent.modifierFlags.contains(.command) { range = word(at: point)?.range }
                if range != hovered { hovered = range }
            }
            .gesture(SpatialTapGesture().modifiers(.command).onEnded { value in
                if let word = word(at: value.location) { symbol = Symbol(name: word.name) }
            })
            .popover(item: $symbol, arrowEdge: .bottom) { item in
                DefinitionPopover(pr: pr, name: item.name, path: path) { symbol = nil }
            }
    }

    private var underlined: AttributedString {
        guard let hovered, hovered.upperBound <= text.characters.count else { return text }
        var result = text
        let start = result.index(result.startIndex, offsetByCharacters: hovered.lowerBound)
        let end = result.index(result.startIndex, offsetByCharacters: hovered.upperBound)
        result[start..<end].underlineStyle = .single
        return result
    }

    // ponytail: lays the line out again with TextKit in the diff's font to find the character under the pointer.
    // It matches SwiftUI's own layout for monospaced code; if they ever drift, the wrong name gets picked.
    /// The name under a point of the line, unless it's a keyword or the file's language isn't covered.
    private func word(at point: CGPoint) -> (name: String, range: Range<Int>)? {
        guard Definitions.isCovered(path), !line.isEmpty else { return nil }
        let storage = NSTextStorage(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)])
        let container = NSTextContainer(size: CGSize(width: wrap ? max(width, 1) : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyph = layout.glyphIndex(for: point, in: container)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return nil }
        let index = String.Index(utf16Offset: layout.characterIndexForGlyph(at: glyph), in: line)
        guard let word = Definitions.identifier(in: line, at: line.distance(from: line.startIndex, to: index)),
              Syntax.language(for: path)?.keywords.contains(word.name) != true else { return nil }
        return word
    }
}

/// Where a ⌘-clicked name is defined: kind, file and line, whether this PR changes it, the declaration and its docs.
struct DefinitionPopover: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let name: String
    /// The file the name was clicked in.
    let path: String
    let close: () -> Void
    @ViewState private var found: [Match]?
    /// All matches, of which `found` shows the first `limit`.
    @ViewState private var total = 0
    @ViewState private var failure: String?
    private static let limit = 30

    /// A definition with what the popover shows about it, worked out once instead of on every redraw.
    private struct Match {
        var definition: Definition
        var change: Definition.Change
        /// The diff shows its line, so Go to Definition can open it in Changes.
        var inDiff: Bool
        var declaration: AttributedString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let found, !found.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(found.enumerated()), id: \.offset) { index, match in
                            if index > 0 { Divider() }
                            row(match)
                        }
                        if total > found.count {
                            Text("+\(total - found.count) more").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            } else if found != nil {
                Text("No definition of **\(name)** found").font(.headline)
                Text("Searched this pull request's files and the files this one imports, at the head commit. Definitions are found in \(Definitions.coveredLanguages) only.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for \(name)…").foregroundStyle(.secondary)
                }
            }
        }
        .font(.body) // not the diff's monospaced font
        .padding(14)
        .frame(width: 560, alignment: .leading)
        .task {
            do {
                let definitions = try await model.definitions(of: name, from: path, pr: pr)
                total = definitions.count
                found = matches(Array(definitions.prefix(Self.limit)))
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func matches(_ definitions: [Definition]) -> [Match] {
        let files = model.files[pr.id] ?? []
        var shown: [String: Set<Int>] = [:] // head-side lines each diff shows, parsed once per file
        return definitions.map { definition in
            if shown[definition.path] == nil {
                let patch = files.first { $0.filename == definition.path }?.patch ?? ""
                shown[definition.path] = Set(Diff.parse(patch).filter { $0.kind != .removed }.compactMap(\.newLine))
            }
            let language = Syntax.language(for: definition.path)
            let declaration = definition.declaration.components(separatedBy: "\n").map { line in
                FileDiffView.highlighted(line, tokens: language.map { Syntax.tokens(line, language: $0) } ?? [])
            }.reduce(into: AttributedString()) { result, line in
                if !result.characters.isEmpty { result += AttributedString("\n") }
                result += line
            }
            return Match(definition: definition, change: Definitions.change(of: definition, in: files),
                         inDiff: shown[definition.path]?.contains(definition.line) == true, declaration: declaration)
        }
    }

    private func row(_ match: Match) -> some View {
        let definition = match.definition
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Badge(text: definition.kind)
                Text(definition.name).font(.headline.monospaced())
                Spacer()
                switch match.change {
                case .added: Badge(text: "Added in this PR", color: .green)
                case .modified: Badge(text: "Changed in this PR", color: .blue)
                case .untouched: Badge(text: "Not changed")
                }
            }
            Text("\(definition.path):\(definition.line)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text(match.declaration)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DiffColors.editor, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DiffColors.separator))
            if let doc = definition.doc { MarkdownText(doc).font(.callout) }
            Button("Go to Definition") { open(match) }
                .help(match.inDiff ? "Show this line in Changes" : "Open the file on GitHub at this pull request's head commit")
        }
    }

    private func open(_ match: Match) {
        let definition = match.definition
        if match.inDiff {
            close()
            model.changesTarget = LineTarget(path: definition.path, line: definition.line)
        } else if let url = URL(string: "https://github.com/\(pr.repo)/blob/\(pr.headRefOid)/"
                                + (definition.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? definition.path)
                                + "#L\(definition.line)") {
            NSWorkspace.shared.open(url)
        }
    }
}
