import Foundation
import ReviewDeskCore

extension AppModel {
    /// Where `name`, ⌘-clicked in `path`'s diff, is defined, best match first. Searches the PR's files and the files
    /// `path` imports, at the PR's head commit. Nothing goes to an AI provider. On the demo, only the diffs are searched.
    func definitions(of name: String, from path: String, pr: PullRequest) async throws -> [Definition] {
        if files[pr.id] == nil { files[pr.id] = try await github.files(pr.ref) }
        let changed = (files[pr.id] ?? []).filter { $0.status != "removed" }
        var texts: [String: String] = [:]
        var imported: Set<String> = []
        if !pr.isDemo {
            // The clicked file first, so the file cap never leaves out its imports.
            texts = try await headContents(pr, paths: [path] + changed.map(\.filename).filter { $0 != path })
            let candidates = Definitions.imports(texts[path] ?? "", path: path)
            let more = try await headContents(pr, paths: candidates)
            imported = Set(more.keys)
            texts.merge(more) { first, _ in first }
        }
        // A file without its text (binary, too large, past the file cap, or the demo): what its diff shows of the head.
        let patches = changed.filter { texts[$0.filename] == nil }.compactMap { file in file.patch.map { (file.filename, $0) } }
        let sources = texts.sorted { $0.key < $1.key }
        // Off the main actor: a common name in a large pull request means a lot of regex matching.
        let found = await Task.detached {
            patches.flatMap { Definitions.find(name, path: $0.0, lines: Definitions.headLines($0.1)) }
                + sources.flatMap { Definitions.find(name, path: $0.key, source: $0.value) }
        }.value
        return Definitions.rank(found, from: path, imported: imported)
    }

    /// The files' text at the PR's head commit, in languages the matcher covers. Each file is fetched once per
    /// commit, in GraphQL queries of 50 files stored as each one lands; a file another lookup is already fetching
    /// is waited for, not fetched again. Files that don't exist are remembered as such and left out.
    private func headContents(_ pr: PullRequest, paths: [String]) async throws -> [String: String] {
        let sha = pr.headRefOid
        if headFiles[pr.id]?.sha != sha { headFiles[pr.id] = HeadFiles(sha: sha) } // a push: the old texts are stale
        // ponytail: at most 200 files per lookup (4 queries); the rest are searched through their diff's head side.
        // Raise the cap, or search on a linked local clone, if huge pull requests miss definitions.
        let wanted = Array(paths.filter(Definitions.isCovered).prefix(200))
        let missing = wanted.filter { headFiles[pr.id]?.texts[$0] == nil && headFiles[pr.id]?.fetching[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: 50) {
            let batch = Array(missing[start..<min(start + 50, missing.count)])
            let fetch = Task {
                defer { for path in batch where headFiles[pr.id]?.sha == sha { headFiles[pr.id]?.fetching[path] = nil } }
                let fetched = try await github.fileContents(repo: pr.repo, paths: batch, ref: sha)
                guard headFiles[pr.id]?.sha == sha else { return }
                for path in batch { headFiles[pr.id]?.texts[path] = fetched[path] ?? "" }
            }
            for path in batch { headFiles[pr.id]?.fetching[path] = fetch }
        }
        for fetch in Set(wanted.compactMap { headFiles[pr.id]?.fetching[$0] }) { try await fetch.value }
        let texts = headFiles[pr.id]?.texts ?? [:]
        return Dictionary(uniqueKeysWithValues: wanted.compactMap { path in texts[path].flatMap { $0.isEmpty ? nil : (path, $0) } })
    }
}

/// A PR's files at its head commit, read for ⌘-click definitions. In memory only.
struct HeadFiles {
    var sha: String
    /// Path → text; "" for a file that isn't there.
    var texts: [String: String] = [:]
    /// Fetches in flight, by the paths they bring.
    var fetching: [String: Task<Void, any Error>] = [:]
}
