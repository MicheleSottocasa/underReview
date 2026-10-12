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
}

// ponytail: line-by-line regex-free scanner; multi-line strings and block comments aren't tracked across
// lines. Swap in tree-sitter if reviewers need exact highlighting.
public enum Syntax {
    public static func language(for path: String) -> SyntaxLanguage? {
        switch (path as NSString).pathExtension.lowercased() {
        case "py", "pyi": SyntaxLanguage(lineComments: ["#"], keywords: python)
        case "swift": SyntaxLanguage(lineComments: ["//"], keywords: cFamily.union(["func", "let", "var", "guard", "struct", "enum", "protocol", "extension", "init", "self", "Self", "some", "any", "in", "where", "async", "await", "try", "throws", "import", "nil", "public", "private", "fileprivate", "internal", "static"]))
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": SyntaxLanguage(lineComments: ["//"], keywords: cFamily.union(["function", "const", "let", "var", "async", "await", "import", "from", "export", "default", "undefined", "null", "typeof", "instanceof", "interface", "type", "of", "in", "yield"]))
        case "go": SyntaxLanguage(lineComments: ["//"], keywords: cFamily.union(["func", "package", "import", "var", "const", "type", "range", "go", "defer", "chan", "map", "nil", "select", "interface"]))
        case "java", "kt", "kts", "scala", "cs", "c", "h", "cc", "cpp", "hpp", "m", "mm", "rs", "dart", "php":
            SyntaxLanguage(lineComments: ["//"], keywords: cFamily.union(["fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "fun", "val", "var", "object", "package", "import", "null", "nil", "self", "this", "namespace", "using"]))
        case "rb": SyntaxLanguage(lineComments: ["#"], keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "do", "return", "nil", "true", "false", "self", "yield", "require", "begin", "rescue", "ensure"])
        case "sh", "bash", "zsh": SyntaxLanguage(lineComments: ["#"], keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export", "local"])
        case "yml", "yaml", "toml", "ini", "cfg", "dockerfile", "mk": SyntaxLanguage(lineComments: ["#"], keywords: ["true", "false", "null"])
        case "sql": SyntaxLanguage(lineComments: ["--"], keywords: ["select", "from", "where", "insert", "into", "update", "delete", "create", "table", "alter", "drop", "join", "left", "right", "inner", "on", "and", "or", "not", "null", "as", "group", "by", "order", "limit", "values", "set", "index", "primary", "key"])
        default: nil
        }
    }

    public static func tokens(_ line: String, language: SyntaxLanguage) -> [SyntaxToken] {
        let chars = Array(line)
        var tokens: [SyntaxToken] = []
        var i = 0

        func starts(with prefix: String, at index: Int) -> Bool {
            let p = Array(prefix)
            return index + p.count <= chars.count && Array(chars[index..<index + p.count]) == p
        }

        while i < chars.count {
            let c = chars[i]
            if language.lineComments.contains(where: { starts(with: $0, at: i) }) {
                tokens.append(SyntaxToken(range: i..<chars.count, kind: .comment))
                break
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
