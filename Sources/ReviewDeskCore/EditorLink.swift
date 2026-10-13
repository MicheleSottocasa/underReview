import Foundation

/// Opens a file at a line in the user's editor through the editor's URL scheme: no CLI on the PATH needed,
/// and nothing a file name could inject into a command line.
public enum EditorLink {
    /// Name and URL template; `{path}` is the absolute path, `{line}` the 1-based line.
    public static let presets: [(name: String, template: String)] = [
        ("Visual Studio Code", "vscode://file{path}:{line}"),
        ("Cursor", "cursor://file{path}:{line}"),
        ("Windsurf", "windsurf://file{path}:{line}"),
        ("Zed", "zed://file{path}:{line}"),
        ("IntelliJ IDEA", "idea://open?file={path}&line={line}"),
        ("PyCharm", "pycharm://open?file={path}&line={line}"),
    ]

    /// Path characters left as they are: a path's own `/`, but not what would end it or start a query.
    private static let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#&=+;"))

    public static func url(template: String, path: String, line: Int) -> URL? {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: pathAllowed) else { return nil }
        return URL(string: template
            .replacingOccurrences(of: "{path}", with: encoded)
            .replacingOccurrences(of: "{line}", with: String(max(line, 1))))
    }

    /// The new-side line of a patch's first change; for a pure deletion, the line that now follows it.
    public static func firstChange(in patch: String) -> Int {
        let lines = Diff.parse(patch)
        let start = lines.firstIndex { $0.kind == .added || $0.kind == .removed } ?? 0
        return lines[start...].lazy.compactMap(\.newLine).first ?? lines.lazy.compactMap(\.newLine).last ?? 1
    }
}
