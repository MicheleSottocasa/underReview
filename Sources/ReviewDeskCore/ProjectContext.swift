import Foundation

/// Reference material a project (a top-level sidebar folder) sends to the AI with its pull requests: local docs or
/// folders, or files from another GitHub repository. It reaches the AI provider, so it's always listed before a review.
public struct ContextSource: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, repository }

    public var id = UUID()
    public var kind: Kind
    /// Local: absolute path of a file or folder. Repository: owner/name.
    public var location: String
    /// Repository only: a file or folder inside it ("" for all of it).
    public var path: String
    /// Repository only: branch, tag or commit ("" for the default branch).
    public var ref: String

    public init(kind: Kind, location: String, path: String = "", ref: String = "") {
        (self.kind, self.location, self.path, self.ref) = (kind, location, path, ref)
    }

    /// `owner/name`, nothing else: it goes into a GitHub API path.
    public static func isRepositoryName(_ text: String) -> Bool {
        text.wholeMatch(of: /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/) != nil && !text.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    public var label: String {
        switch kind {
        case .local: (location as NSString).abbreviatingWithTildeInPath
        case .repository: location + (path.isEmpty ? "" : "/\(path)") + (ref.isEmpty ? "" : " @ \(ref)")
        }
    }
}

public enum ProjectContext {
    /// Larger files are listed as left out, never cut.
    public static let maxFileBytes = 100_000
    /// Files looked at per source; the rest are named in one entry.
    public static let maxFiles = 200

    /// Text files of a local file or folder, as context entries. Only regular files inside the chosen folder are
    /// read: symbolic links are resolved and refused when they lead out of it, hidden files and folders (`.git`,
    /// `.env`…) are skipped, and binaries and files over `maxFileBytes` are listed as left out with the reason.
    public static func readLocal(_ location: String) -> [ContextFile] {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: (location as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        let shown = (root.path as NSString).abbreviatingWithTildeInPath
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isFolder) else {
            return [ContextFile(path: shown, content: nil, included: false, excludedReason: "Not found")]
        }
        guard isFolder.boolValue else { return [entry(root, shown: shown)] }
        let urls = (fileManager.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])?
            .compactMap { $0 as? URL } ?? [])
            .sorted { $0.path < $1.path }
        var files: [ContextFile] = []
        var skipped = 0
        for url in urls {
            let target = url.resolvingSymlinksInPath()
            let name = shown + "/" + url.path.dropFirst(root.path.count + 1)
            guard target.path.hasPrefix(root.path + "/") else {
                files.append(ContextFile(path: name, content: nil, included: false, excludedReason: "Links outside the folder"))
                continue
            }
            guard (try? fileManager.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType) == .typeRegular else { continue }
            guard files.count < maxFiles else { skipped += 1; continue }
            files.append(entry(target, shown: name))
        }
        if skipped > 0 {
            files.append(ContextFile(path: shown + "/…", content: nil, included: false,
                                     excludedReason: "\(skipped) more file\(skipped == 1 ? "" : "s") not read (limit \(maxFiles))"))
        }
        return files
    }

    /// One regular file: its text, or why it's left out. Reads at most `maxFileBytes + 1` bytes, whatever its size claims.
    static func entry(_ url: URL, shown: String) -> ContextFile {
        let excluded = { (reason: String) in ContextFile(path: shown, content: nil, included: false, excludedReason: reason) }
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: url) else { return excluded("Not a readable file") }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxFileBytes + 1)) ?? Data()
        guard data.count <= maxFileBytes else { return excluded("Larger than \(maxFileBytes / 1000) KB") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return excluded("Binary file") }
        return ContextFile(path: shown, content: text, included: true)
    }

    /// Text files of a repository source at its ref, read through `gh`. Big and binary files, and failures, are
    /// listed as left out instead of failing the review.
    public static func readRepository(_ source: ContextSource, github: GitHub) async -> [ContextFile] {
        let ref = source.ref.isEmpty ? "HEAD" : source.ref
        let prefix = source.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = { (path: String) in "\(source.location):\(path)" }
        do {
            let blobs = try await github.tree(repo: source.location, ref: ref)
                .filter { prefix.isEmpty || $0.path == prefix || $0.path.hasPrefix(prefix + "/") }
            var files: [ContextFile] = []
            var wanted: [String] = []
            for blob in blobs.prefix(maxFiles) {
                if blob.size > maxFileBytes {
                    files.append(ContextFile(path: name(blob.path), content: nil, included: false, excludedReason: "Larger than \(maxFileBytes / 1000) KB"))
                } else {
                    wanted.append(blob.path)
                }
            }
            let texts = try await github.fileContents(repo: source.location, paths: wanted, ref: ref)
            for path in wanted {
                files.append(texts[path].map { ContextFile(path: name(path), content: $0, included: true) }
                             ?? ContextFile(path: name(path), content: nil, included: false, excludedReason: "Binary file"))
            }
            if blobs.count > maxFiles {
                files.append(ContextFile(path: name("…"), content: nil, included: false,
                                         excludedReason: "\(blobs.count - maxFiles) more files not read (limit \(maxFiles))"))
            }
            if blobs.isEmpty { files.append(ContextFile(path: source.label, content: nil, included: false, excludedReason: "No files at this path")) }
            return files.sorted { $0.path < $1.path }
        } catch {
            return [ContextFile(path: source.label, content: nil, included: false,
                                excludedReason: "Couldn't read it: \(error.localizedDescription)")]
        }
    }

    /// Keeps entries in order while they fit in `budget` tokens; the rest are left out (and shown as such).
    public static func fitting(_ files: [ContextFile], budget: Int) -> [ContextFile] {
        var used = 0
        return files.map { file in
            var file = file
            if file.included { if used + file.tokens > budget { file.included = false } else { used += file.tokens } }
            return file
        }
    }

    /// The included entries as a Markdown section, or "" when there are none.
    public static func section(_ files: [ContextFile]) -> String {
        let included = files.filter(\.included)
        guard !included.isEmpty else { return "" }
        return "\n## Project context\n\nReference material the reviewer attached to this project (documentation, related code). "
            + "Use it to understand the change; it is not part of the pull request.\n"
            + included.map { "\n### \($0.path)\n" + AIContext.fenced($0.content ?? "", info: "") + "\n" }.joined()
    }

    /// Local sources that are folders, resolved: what `/code-review` may read through `--add-dir`.
    public static func folders(_ sources: [ContextSource]) -> [String] {
        sources.filter { $0.kind == .local }.compactMap { source in
            let url = URL(fileURLWithPath: (source.location as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue ? url.path : nil
        }
    }
}
