import Foundation

/// The repository's own rules for contributors and AI agents, checked by every review.
public enum RepoRules {
    /// Read at the repository root.
    public static let rootFiles = [
        "AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", ".github/CONTRIBUTING.md", "docs/CONTRIBUTING.md",
        ".github/copilot-instructions.md", ".cursorrules",
    ]
    /// Read in every folder above a changed file too: nested rules apply to their part of the tree.
    public static let nestedFiles = ["AGENTS.md", "CLAUDE.md"]
    /// Longer files are cut, and the cut is stated in the prompt.
    public static let maxCharacters = 20_000

    /// A project's own rule entry points (Project › AI Context…), e.g. `docs/AGENTS.md` or `.cursor/rules/review.md`,
    /// as typed: one per line or comma-separated, from the repository root. A leading `/` or `./` is dropped, and a path
    /// stepping out of the repository (`..`) or naming a folder (trailing `/`) is ignored. Duplicates go once.
    public static func entryPoints(from text: String) -> [String] {
        var result: [String] = []
        for item in text.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            var path = item.trimmingCharacters(in: .whitespaces)
            while path.hasPrefix("/") || path.hasPrefix("./") { path.removeFirst(path.hasPrefix("/") ? 1 : 2) }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasSuffix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !result.contains(path) else { continue }
            result.append(path)
        }
        return result
    }

    /// Paths to look for, root rules first, then nested ones from the shallowest folder down. A project's
    /// `entryPoints` replace the root files; nested rules are still read.
    public static func candidates(changed: [String], entryPoints: [String] = []) -> [String] {
        var folders: [String] = []
        for path in changed {
            var parts = path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                let folder = parts.joined(separator: "/")
                if !folders.contains(folder) { folders.append(folder) }
                parts = parts.dropLast()
            }
        }
        folders.sort { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
        let roots = entryPoints.isEmpty ? rootFiles : entryPoints
        // An entry point can also be a nested rule file (docs/AGENTS.md): it's looked for once, as an entry point.
        return roots + folders.flatMap { folder in nestedFiles.map { "\(folder)/\($0)" } }.filter { !roots.contains($0) }
    }

    /// The rules found, in candidate order, as context entries the user can see and deselect.
    public static func contextFiles(_ found: [String: String], changed: [String], entryPoints: [String] = []) -> [ContextFile] {
        candidates(changed: changed, entryPoints: entryPoints).compactMap { path in
            guard let text = found[path]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let content = text.count <= maxCharacters ? text
                : text.prefix(maxCharacters) + "\n\n[ReviewDesk cut this file at \(maxCharacters) of \(text.count) characters.]"
            return ContextFile(path: path, patch: nil, content: content, included: true)
        }
    }

    /// The rules as Markdown sections, or "" when there are none.
    public static func section(_ rules: [ContextFile]) -> String {
        let included = rules.filter(\.included)
        guard !included.isEmpty else { return "" }
        return "\n## Repository rules\n\nThe repository's own rules, from its base branch. Check the change against them.\n"
            + included.map { "\n### \($0.path)\n\n\($0.content ?? "")\n" }.joined()
    }

}
