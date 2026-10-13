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
            texts = try await headContents(pr, paths: changed.map(\.filename))
            let candidates = Definitions.imports(texts[path] ?? "", path: path)
            let more = try await headContents(pr, paths: candidates)
            imported = Set(more.keys)
            texts.merge(more) { first, _ in first }
        }
        // A file whose text GitHub didn't give (binary, too large, or the demo): what its diff shows of the head.
        let patches = changed.filter { texts[$0.filename] == nil }.compactMap { file in file.patch.map { (file.filename, $0) } }
        let sources = texts.sorted { $0.key < $1.key }
        // Off the main actor: a common name in a large pull request means a lot of regex matching.
        let found = await Task.detached {
            patches.flatMap { Definitions.find(name, path: $0.0, lines: Definitions.headLines($0.1)) }
                + sources.flatMap { Definitions.find(name, path: $0.key, source: $0.value) }
        }.value
        return Definitions.rank(found, from: path, imported: imported)
    }

    /// The files' text at the PR's head commit, in languages the matcher covers. Each commit's files are fetched
    /// once (one GraphQL query per 50 files); files that don't exist are remembered as such and left out.
    private func headContents(_ pr: PullRequest, paths: [String]) async throws -> [String: String] {
        let wanted = paths.filter(Definitions.isCovered)
        let missing = wanted.filter { headFiles[pr.headRefOid]?[$0] == nil }
        if !missing.isEmpty {
            let fetched = try await github.fileContents(repo: pr.repo, paths: missing, ref: pr.headRefOid)
            for path in missing { headFiles[pr.headRefOid, default: [:]][path] = fetched[path] ?? "" }
        }
        let cached = headFiles[pr.headRefOid] ?? [:]
        return Dictionary(uniqueKeysWithValues: wanted.compactMap { path in cached[path].flatMap { $0.isEmpty ? nil : (path, $0) } })
    }
}
