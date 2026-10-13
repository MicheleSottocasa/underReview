import Foundation

/// Where a symbol is defined, as shown by ⌘-click in the diff.
public struct Definition: Hashable, Sendable {
    public enum Change: String, Sendable { case added, modified, untouched }

    /// function, method, class, struct, enum, protocol, actor, interface, type, typealias, constant or variable.
    public var kind: String
    public var name: String
    public var path: String
    public var line: Int
    /// The signature up to the body opener (`:` or `{`), or the whole statement for a constant or variable.
    public var declaration: String
    /// The doc comment above the declaration, or a Python docstring, without its comment markers.
    public var doc: String?

    public var lineCount: Int { declaration.split(separator: "\n", omittingEmptySubsequences: false).count }
}

// ponytail: one regex per kind of declaration and language, no parser. It can't tell scopes apart (a local
// `let` matches too) and misses unusual layouts; switch to a language server if it misses too often.
/// Finds definitions in source text: Python, Swift, JavaScript/TypeScript and Go. Other languages find nothing.
public enum Definitions {
    struct Language {
        /// `NAME` stands for the symbol. A nil kind takes the first capture group (`class`, `let`, …).
        var patterns: [(kind: String?, template: String)]
        /// The body opener a declaration ends before (constants and variables run to the end of the statement).
        var opener: Character
        var comments: [String]
        /// Line prefixes of doc comments directly above a declaration.
        var lineDocs: [String]
        var blockDocs = false
        var docstrings = false
    }

    public static let coveredLanguages = "Python, Swift, JavaScript, TypeScript and Go"

    static func language(for path: String) -> Language? {
        switch (path as NSString).pathExtension.lowercased() {
        case "py", "pyi":
            Language(patterns: [
                ("function", #"^\s*(?:async\s+)?def\s+NAME\s*[\[(]"#),
                ("class", #"^\s*class\s+NAME\b"#),
                ("variable", #"^NAME\s*(?::[^=]+)?=(?!=)"#),
            ], opener: ":", comments: ["#"], lineDocs: ["#"], docstrings: true)
        case "swift":
            Language(patterns: [
                ("function", #"\bfunc\s+NAME\s*[<(]"#),
                (nil, #"\b(class|struct|enum|protocol|actor|typealias)\s+NAME\b"#),
                (nil, #"\b(let|var)\s+NAME\b"#),
            ], opener: "{", comments: ["//", "/*", "*"], lineDocs: ["///"], blockDocs: true)
        case "js", "jsx", "ts", "tsx", "mjs", "cjs":
            Language(patterns: [
                ("function", #"\bfunction\s*\*?\s*NAME\s*[<(]"#),
                (nil, #"\b(class|interface|enum|type)\s+NAME\b"#),
                (nil, #"\b(const|let|var)\s+NAME\b"#),
                ("method", #"^\s*(?:(?:public|private|protected|static|async|readonly|get|set|override)\s+)*NAME\s*(?:<[^>]*>)?\s*\([^;]*\)\s*(?::[^{;]*)?\{"#),
            ], opener: "{", comments: ["//", "/*", "*"], lineDocs: ["//"], blockDocs: true)
        case "go":
            Language(patterns: [
                ("function", #"^func\s+(\([^)]*\)\s*)?NAME\s*[\[(]"#),
                ("type", #"^\s*type\s+NAME\b"#),
                (nil, #"^\s*(const|var)\s+NAME\b"#),
            ], opener: "{", comments: ["//", "/*", "*"], lineDocs: ["//"], blockDocs: true)
        default: nil
        }
    }

    public static func isCovered(_ path: String) -> Bool { language(for: path) != nil }

    /// Every definition of `name` in a whole file.
    public static func find(_ name: String, path: String, source: String) -> [Definition] {
        find(name, path: path, lines: source.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, $0.element) })
    }

    /// Every definition of `name` in numbered lines: a whole file, or only the head side of a patch.
    public static func find(_ name: String, path: String, lines: [(number: Int, text: String)]) -> [Definition] {
        guard let language = language(for: path), identifier(in: name, at: 0)?.name == name else { return [] }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = language.patterns.compactMap { pattern in
            (try? NSRegularExpression(pattern: pattern.template.replacingOccurrences(of: "NAME", with: escaped))).map { (pattern.kind, $0) }
        }
        var found: [Definition] = []
        for (index, line) in lines.enumerated() where line.text.contains(name) {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !language.comments.contains(where: trimmed.hasPrefix) else { continue }
            let text = line.text as NSString
            for (fixed, regex) in patterns {
                guard let match = regex.firstMatch(in: line.text, range: NSRange(location: 0, length: text.length)) else { continue }
                let group = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? text.substring(with: match.range(at: 1)) : nil
                var kind = fixed ?? group ?? "variable"
                switch kind {
                case "let", "const": kind = "constant"
                case "var": kind = "variable"
                case "variable" where name == name.uppercased(): kind = "constant"
                case "function" where line.text.first?.isWhitespace == true || group != nil: kind = "method"
                default: break
                }
                let declaration = declaration(lines, from: index, opener: kind == "constant" || kind == "variable" ? nil : language.opener)
                let after = index + declaration.split(separator: "\n", omittingEmptySubsequences: false).count
                let doc = (language.docstrings ? docstring(lines, from: after) : nil) ?? comment(above: index, in: lines, language: language)
                found.append(Definition(kind: kind, name: name, path: path, line: line.number, declaration: declaration, doc: doc))
                break
            }
        }
        return found
    }

    /// From the declaration's line up to the body opener at bracket depth 0, or to the end of the statement.
    static func declaration(_ lines: [(number: Int, text: String)], from start: Int, opener: Character?) -> String {
        var result: [String] = []
        var depth = 0
        for line in lines[start..<min(start + 12, lines.count)] {
            var kept = ""
            for char in line.text {
                if depth == 0, char == opener { result.append(kept); return trim(result) }
                if "([".contains(char) { depth += 1 } else if ")]".contains(char) { depth -= 1 }
                kept.append(char)
            }
            result.append(kept)
            if depth <= 0 { break }
        }
        return trim(result)
    }

    private static func trim(_ lines: [String]) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Python docstring: the string literal right after the declaration.
    static func docstring(_ lines: [(number: Int, text: String)], from start: Int) -> String? {
        guard let index = lines[start...].firstIndex(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let opening = lines[index].text.trimmingCharacters(in: .whitespaces).drop { "rRuUbB".contains($0) }
        guard let quote = [#"""""#, "'''"].first(where: { opening.hasPrefix($0) }) else { return nil }
        var body = String(opening.dropFirst(3))
        if let end = body.range(of: quote) { return clean(String(body[..<end.lowerBound])) }
        for line in lines[(index + 1)...].prefix(80) {
            if let end = line.text.range(of: quote) { return clean(body + "\n" + line.text[..<end.lowerBound]) }
            body += "\n" + line.text
        }
        return nil
    }

    /// The comment block directly above the declaration, skipping attributes and decorators.
    static func comment(above start: Int, in lines: [(number: Int, text: String)], language: Language) -> String? {
        var index = start - 1
        while index >= 0, lines[index].text.trimmingCharacters(in: .whitespaces).hasPrefix("@") { index -= 1 }
        guard index >= 0 else { return nil }
        let last = lines[index].text.trimmingCharacters(in: .whitespaces)
        var docs: [String] = []
        if language.blockDocs, last.hasSuffix("*/") {
            while index >= 0 {
                let text = lines[index].text.trimmingCharacters(in: .whitespaces)
                docs.insert(text, at: 0)
                if text.hasPrefix("/*") { break }
                index -= 1
            }
            return clean(docs.map { line in
                var text = Substring(line)
                if text.hasPrefix("/**") { text = text.dropFirst(3) } else if text.hasPrefix("/*") { text = text.dropFirst(2) }
                if text.hasSuffix("*/") { text = text.dropLast(2) }
                text = text.drop { $0 == " " }
                if text.hasPrefix("*") { text = text.dropFirst().drop { $0 == " " } }
                return String(text)
            }.joined(separator: "\n"))
        }
        while index >= 0 {
            let text = lines[index].text.trimmingCharacters(in: .whitespaces)
            guard let prefix = language.lineDocs.first(where: text.hasPrefix) else { break }
            var rest = text.dropFirst(prefix.count)
            if rest.first == " " { rest = rest.dropFirst() }
            docs.insert(String(rest), at: 0)
            index -= 1
        }
        return clean(docs.joined(separator: "\n"))
    }

    /// Trims, and removes the indentation every line shares.
    private static func clean(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let indent = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let result = ([lines[0]] + lines.dropFirst().map { String($0.dropFirst(min(indent, $0.count))) })
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// The identifier at a character offset of a line, with its range.
    public static func identifier(in line: String, at offset: Int) -> (name: String, range: Range<Int>)? {
        let chars = Array(line)
        guard chars.indices.contains(offset), isIdentifier(chars[offset]) else { return nil }
        var start = offset, end = offset + 1
        while start > 0, isIdentifier(chars[start - 1]) { start -= 1 }
        while end < chars.count, isIdentifier(chars[end]) { end += 1 }
        guard !chars[start].isNumber else { return nil }
        return (String(chars[start..<end]), start..<end)
    }

    private static func isIdentifier(_ char: Character) -> Bool { char.isLetter || char.isNumber || char == "_" || char == "$" }

    /// The head side of a patch, numbered: what's known of a file when its full text isn't.
    public static func headLines(_ patch: String) -> [(number: Int, text: String)] {
        Diff.parse(patch).compactMap { line in line.kind == .removed ? nil : line.newLine.map { ($0, line.text) } }
    }

    /// Paths in the repository that a file may import from, relative ones resolved against its folder:
    /// Python modules and JavaScript/TypeScript relative imports. Swift and Go import modules and packages, not files.
    public static func imports(_ source: String, path: String) -> [String] {
        let folder = (path as NSString).deletingLastPathComponent
        var paths: [String] = []
        switch (path as NSString).pathExtension.lowercased() {
        case "py", "pyi":
            for match in matches(#"(?m)^\s*from\s+(\.*)([\w.]*)\s+import\s+\(?([\w ,]+)"#, in: source) {
                let base = match[1].isEmpty ? "" : ([folder] + Array(repeating: "..", count: match[1].count - 1)).joined(separator: "/")
                let module = join(base, match[2].replacingOccurrences(of: ".", with: "/"))
                if !match[2].isEmpty { paths += [module + ".py", join(module, "__init__.py")] }
                for name in match[3].split(separator: ",") {
                    guard let word = name.split(separator: " ").first else { continue }
                    paths.append(join(module, word + ".py"))
                }
            }
            for match in matches(#"(?m)^\s*import\s+([\w.]+)"#, in: source) {
                let module = match[1].replacingOccurrences(of: ".", with: "/")
                paths += [module + ".py", module + "/__init__.py"]
            }
        case "js", "jsx", "ts", "tsx", "mjs", "cjs":
            for match in matches(#"(?:from|import|require\()\s*['"](\.{1,2}/[^'"]+)['"]"#, in: source) {
                let file = join(folder, match[1])
                let stem = ["js", "jsx", "mjs", "cjs"].contains((file as NSString).pathExtension) ? (file as NSString).deletingPathExtension : file
                paths += [file] + ["ts", "tsx", "js", "jsx"].map { stem + "." + $0 } + ["ts", "tsx", "js"].map { file + "/index." + $0 }
            }
        default: break
        }
        var seen = Set<String>()
        return paths.map(normalize).filter { !$0.hasPrefix("..") && seen.insert($0).inserted }
    }

    private static func join(_ a: String, _ b: some StringProtocol) -> String { a.isEmpty ? String(b) : b.isEmpty ? a : a + "/" + b }

    /// Resolves `.` and `..` components.
    private static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == "..", let last = parts.last, last != ".." { parts.removeLast() } else { parts.append(part) }
        }
        return parts.joined(separator: "/")
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }

    /// Same file first, then files the clicked file imports, then everything else; file order otherwise.
    public static func rank(_ definitions: [Definition], from path: String, imported: Set<String>) -> [Definition] {
        definitions.enumerated().sorted { a, b in
            func group(_ definition: Definition) -> Int { definition.path == path ? 0 : imported.contains(definition.path) ? 1 : 2 }
            return (group(a.element), a.offset) < (group(b.element), b.offset)
        }.map(\.element)
    }

    /// Whether the PR adds the declaration (every line of it added), modifies it (some lines) or leaves it untouched.
    public static func change(of definition: Definition, in files: [FileChange]) -> Definition.Change {
        guard let file = files.first(where: { $0.filename == definition.path }) else { return .untouched }
        guard let patch = file.patch else { return file.status == "added" ? .added : .untouched }
        let added = Set(Diff.parse(patch).filter { $0.kind == .added }.compactMap(\.newLine))
        let span = definition.line..<definition.line + definition.lineCount
        let hits = span.filter(added.contains).count
        return hits == span.count ? .added : hits > 0 ? .modified : .untouched
    }
}
