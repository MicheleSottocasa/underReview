import Foundation

public enum DiffSide: String, Codable, Hashable, Sendable {
    case left = "LEFT", right = "RIGHT"
}

/// Where an inline comment sits, in GitHub's line/side model.
public struct Anchor: Codable, Hashable, Sendable {
    public var path: String
    public var line: Int
    public var side: DiffSide

    public init(path: String, line: Int, side: DiffSide = .right) {
        self.path = path
        self.line = line
        self.side = side
    }
}

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case hunk, context, added, removed }

    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?

    /// The anchor a comment on this line would use, if GitHub accepts one here.
    public func anchor(path: String) -> Anchor? {
        switch kind {
        case .hunk: nil
        case .removed: oldLine.map { Anchor(path: path, line: $0, side: .left) }
        case .added, .context: newLine.map { Anchor(path: path, line: $0, side: .right) }
        }
    }
}

public enum Diff {
    /// Parses a GitHub `patch` (hunks of one file).
    public static func parse(_ patch: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var old = 0, new = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            if text.hasPrefix("@@") {
                let numbers = hunkStarts(text)
                (old, new) = (numbers.old, numbers.new)
                lines.append(DiffLine(kind: .hunk, text: text))
            } else if text.hasPrefix("+") {
                lines.append(DiffLine(kind: .added, text: String(text.dropFirst()), newLine: new))
                new += 1
            } else if text.hasPrefix("-") {
                lines.append(DiffLine(kind: .removed, text: String(text.dropFirst()), oldLine: old))
                old += 1
            } else if text.hasPrefix("\\") || text.isEmpty {
                continue // "\ No newline at end of file", or the patch's trailing newline
            } else if !lines.isEmpty {
                lines.append(DiffLine(kind: .context, text: String(text.dropFirst()), oldLine: old, newLine: new))
                old += 1
                new += 1
            }
        }
        return lines
    }

    /// Every anchor GitHub will accept for this file: lines must be inside a hunk.
    public static func anchors(path: String, patch: String) -> Set<Anchor> {
        Set(parse(patch).compactMap { $0.anchor(path: path) })
    }

    static func hunkStarts(_ header: String) -> (old: Int, new: Int) {
        // @@ -12,7 +12,9 @@ optional section
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            let token = parts.first { $0.first == prefix }?.dropFirst() ?? ""
            return Int(token.split(separator: ",").first ?? "") ?? 0
        }
        return (start("-"), start("+"))
    }
}

/// One row of a side-by-side diff: removed lines on the left, added on the right, context on both.
public struct DiffRow: Hashable, Sendable {
    public var left: DiffLine?
    public var right: DiffLine?
    /// Set for hunk headers, which span both sides.
    public var hunk: String?
}

extension Diff {
    /// Pairs each run of removed lines with the added lines that follow it.
    public static func sideBySide(_ lines: [DiffLine]) -> [DiffRow] {
        var rows: [DiffRow] = []
        var removed: [DiffLine] = []
        var paired = 0 // added lines already matched against `removed`

        func flush() {
            rows += removed.dropFirst(paired).map { DiffRow(left: $0) }
            removed = []
            paired = 0
        }

        for line in lines {
            switch line.kind {
            case .hunk:
                flush()
                rows.append(DiffRow(hunk: line.text))
            case .context:
                flush()
                rows.append(DiffRow(left: line, right: line))
            case .removed:
                if paired > 0 { flush() }
                removed.append(line)
            case .added:
                if paired < removed.count {
                    rows.append(DiffRow(left: removed[paired], right: line))
                    paired += 1
                } else {
                    rows.append(DiffRow(right: line))
                }
            }
        }
        flush()
        return rows
    }
}
