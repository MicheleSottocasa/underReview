import Foundation

/// One Codable value persisted as a JSON file. Separate files let the cache be wiped without touching notes or drafts.
public struct JSONFile<Value: Codable>: Sendable {
    public let url: URL

    public init(_ url: URL) { self.url = url }

    public static func appSupport(_ name: String) -> JSONFile {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReviewDesk", isDirectory: true)
        return JSONFile(dir.appendingPathComponent(name))
    }

    public func load(default value: Value) -> Value {
        guard let data = try? Data(contentsOf: url) else { return value }
        return (try? JSONDecoder.iso.decode(Value.self, from: data)) ?? value
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The PR list as of the last successful refresh, so the sidebar fills at launch before GitHub answers.
/// PR details (conversation, threads, files) aren't cached: they load on demand.
public struct PRCache: Codable, Sendable {
    public var prs: [String: PullRequest]
    /// When the list was fetched, and when every PR was last refetched regardless of its update time.
    public var refreshed: Date?
    public var fullRefresh: Date

    public init(prs: [String: PullRequest] = [:], refreshed: Date? = nil, fullRefresh: Date = .distantPast) {
        self.prs = prs
        self.refreshed = refreshed
        self.fullRefresh = fullRefresh
    }
}

/// A folder without a parent is a project.
public struct Folder: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var parentID: UUID?

    public init(name: String, parentID: UUID? = nil) {
        self.name = name
        self.parentID = parentID
    }
}

/// Local-only organisation. Items are keyed by `ItemKey` strings: one per standalone PR or per stack.
public struct Organization: Codable, Sendable, Equatable {
    public var folders: [Folder] = []
    /// item key → folder. Each item has at most one location.
    public var placements: [String: UUID] = [:]
    /// PRs added by URL: node id → URL.
    public var followed: [String: String] = [:]
    /// PR node ids the user stopped monitoring (also hides inbox PRs).
    public var unfollowed: Set<String> = []
    /// item key → private note.
    public var notes: [String: String] = [:]
    /// item keys with notifications muted.
    public var muted: Set<String> = []

    public init() {}

    @discardableResult
    public mutating func addFolder(_ name: String, in parent: UUID? = nil) -> Folder {
        let folder = Folder(name: name, parentID: parent)
        folders.append(folder)
        return folder
    }

    public mutating func renameFolder(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
    }

    /// Deletes the folder and its subfolders; items inside go back to unfiled.
    public mutating func deleteFolder(_ id: UUID) {
        var doomed: Set<UUID> = [id]
        var grew = true
        while grew {
            let children = folders.filter { $0.parentID.map(doomed.contains) == true }.map(\.id)
            grew = !Set(children).isSubset(of: doomed)
            doomed.formUnion(children)
        }
        folders.removeAll { doomed.contains($0.id) }
        placements = placements.filter { !doomed.contains($0.value) }
    }

    /// `nil` folder means unfiled.
    public mutating func place(_ itemKey: String, in folder: UUID?) {
        placements[itemKey] = folder
    }

    public func items(in folder: UUID) -> Set<String> {
        Set(placements.filter { $0.value == folder }.keys)
    }

    public func children(of parent: UUID?) -> [Folder] {
        folders.filter { $0.parentID == parent }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public mutating func follow(id: String, url: String) {
        followed[id] = url
        unfollowed.remove(id)
    }

    public mutating func unfollow(id: String) {
        followed[id] = nil
        unfollowed.insert(id)
    }
}
