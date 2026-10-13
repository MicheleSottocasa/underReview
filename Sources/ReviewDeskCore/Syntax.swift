import Foundation

public enum SyntaxKind: Hashable, Sendable {
    case comment, string, keyword, number, call
}

public struct SyntaxToken: Hashable, Sendable {
    /// Character offsets into the line.
    public var range: Range<Int>
    public var kind: SyntaxKind
}

public struct SyntaxLanguage: Hashable, Sendable {
    public var lineComments: [String]
    public var keywords: Set<String>
    /// Delimiters of strings that can span lines (Python docstrings, Swift `"""`, JS template literals).
    public var blockStrings: [String] = []
}

// ponytail: regex-free scanner. Multi-line strings carry across lines, but each diff hunk starts outside one
// and block comments aren't tracked. Swap in tree-sitter if reviewers need exact highlighting.
public enum Syntax {
    public static func language(for path: String) -> SyntaxLanguage? {
        switch (path as NSString).pathExtension.lowercased() {
        case "py", "pyi": SyntaxLanguage(lineComments: ["#"], keywords: python, blockStrings: [#"""""#, "'''"])
        case "swift": SyntaxLanguage(lineComments: ["//"], keywords: cFamily.union(["func", "let", "var", "guard", "struct", "enum", "protocol", "extension", "init", "self", "Self", "some", "any", "in", "where", "async", "await", "try", "throws", "import", "nil", "public", "private", "fileprivate", "internal", "static"]), blockStrings: [#"""""#])
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": SyntaxLanguage(lineComments: ["//"], keywords: cFamily.union(["function", "const", "let", "var", "async", "await", "import", "from", "export", "default", "undefined", "null", "typeof", "instanceof", "interface", "type", "of", "in", "yield"]), blockStrings: ["`"])
        case "go": SyntaxLanguage(lineComments: ["//"], keywords: cFamily.union(["func", "package", "import", "var", "const", "type", "range", "go", "defer", "chan", "map", "nil", "select", "interface"]), blockStrings: ["`"])
        case "java", "kt", "kts", "scala", "cs", "c", "h", "cc", "cpp", "hpp", "m", "mm", "rs", "dart", "php":
            SyntaxLanguage(lineComments: ["//"], keywords: cFamily.union(["fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "fun", "val", "var", "object", "package", "import", "null", "nil", "self", "this", "namespace", "using"]), blockStrings: [#"""""#])
        case "rb": SyntaxLanguage(lineComments: ["#"], keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "do", "return", "nil", "true", "false", "self", "yield", "require", "begin", "rescue", "ensure"])
        case "sh", "bash", "zsh": SyntaxLanguage(lineComments: ["#"], keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export", "local"])
        case "yml", "yaml", "toml", "ini", "cfg", "dockerfile", "mk": SyntaxLanguage(lineComments: ["#"], keywords: ["true", "false", "null"])
        case "sql": SyntaxLanguage(lineComments: ["--"], keywords: ["select", "from", "where", "insert", "into", "update", "delete", "create", "table", "alter", "drop", "join", "left", "right", "inner", "on", "and", "or", "not", "null", "as", "group", "by", "order", "limit", "values", "set", "index", "primary", "key"])
        default: nil
        }
    }

    public static func tokens(_ line: String, language: SyntaxLanguage) -> [SyntaxToken] {
        var open: String?
        return tokens(line, language: language, open: &open)
    }

    /// Tokens of one line. `open` is the delimiter of a multi-line string still open from earlier lines,
    /// and is updated for the next line.
    public static func tokens(_ line: String, language: SyntaxLanguage, open: inout String?) -> [SyntaxToken] {
        let chars = Array(line)
        var tokens: [SyntaxToken] = []
        var i = 0

        func starts(with prefix: String, at index: Int) -> Bool {
            let p = Array(prefix)
            return index + p.count <= chars.count && Array(chars[index..<index + p.count]) == p
        }

        /// End of the block string closing with `delimiter` at or after `from`, or nil if it runs past the line.
        func close(_ delimiter: String, from: Int) -> Int? {
            var j = from
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if starts(with: delimiter, at: j) { return j + delimiter.count }
                j += 1
            }
            return nil
        }

        if let delimiter = open {
            guard let end = close(delimiter, from: 0) else {
                if !chars.isEmpty { tokens.append(SyntaxToken(range: 0..<chars.count, kind: .string)) }
                return tokens
            }
            tokens.append(SyntaxToken(range: 0..<end, kind: .string))
            open = nil
            i = end
        }

        while i < chars.count {
            let c = chars[i]
            if language.lineComments.contains(where: { starts(with: $0, at: i) }) {
                tokens.append(SyntaxToken(range: i..<chars.count, kind: .comment))
                break
            }
            if let delimiter = language.blockStrings.first(where: { starts(with: $0, at: i) }) {
                guard let end = close(delimiter, from: i + delimiter.count) else {
                    tokens.append(SyntaxToken(range: i..<chars.count, kind: .string))
                    open = delimiter
                    break
                }
                tokens.append(SyntaxToken(range: i..<end, kind: .string))
                i = end
                continue
            }
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != c {
                    j += chars[j] == "\\" ? 2 : 1
                }
                let end = min(j + 1, chars.count)
                tokens.append(SyntaxToken(range: i..<end, kind: .string))
                i = end
                continue
            }
            if c.isNumber, i == 0 || !isIdentifier(chars[i - 1]) {
                var j = i
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "_" || chars[j] == "x" { j += 1 }
                tokens.append(SyntaxToken(range: i..<j, kind: .number))
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, isIdentifier(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                if language.keywords.contains(word) {
                    tokens.append(SyntaxToken(range: i..<j, kind: .keyword))
                } else if k < chars.count, chars[k] == "(" {
                    tokens.append(SyntaxToken(range: i..<j, kind: .call))
                }
                i = j
                continue
            }
            i += 1
        }
        return tokens
    }

    /// Tokens for every line of a diff. Old and new sides keep their own multi-line string state,
    /// since removed and added lines interleave; each hunk starts fresh.
    public static func tokens(diff lines: [DiffLine], language: SyntaxLanguage) -> [DiffLine: [SyntaxToken]] {
        var result: [DiffLine: [SyntaxToken]] = [:]
        var old: String?, new: String?
        for line in lines {
            switch line.kind {
            case .hunk:
                (old, new) = (nil, nil)
            case .removed:
                result[line] = tokens(line.text, language: language, open: &old)
            case .added:
                result[line] = tokens(line.text, language: language, open: &new)
            case .context:
                result[line] = tokens(line.text, language: language, open: &new)
                old = new
            }
        }
        return result
    }

    private static func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    private static let cFamily: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "class",
        "struct", "enum", "new", "true", "false", "try", "catch", "finally", "throw", "public", "private",
        "protected", "static", "final", "void", "int", "bool", "string", "const", "override", "abstract",
    ]

    private static let python: Set<String> = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "None",
        "True", "False", "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "yield",
        "async", "await", "pass", "break", "continue", "global", "nonlocal", "assert", "del", "self",
    ]
}
