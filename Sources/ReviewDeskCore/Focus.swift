import Foundation

/// A file to read before submitting a review, and why.
public struct FocusFile: Hashable, Sendable {
    public var path: String
    /// The AI's key areas in this file, in its order of importance.
    public var areas: [KeyArea]
    /// Comments not submitted yet: local drafts and the pending review on GitHub.
    public var pendingComments: Int
}

public enum Focus {
    /// The AI's key files first, in its order, then every other file with pending comments.
    /// Paths that aren't among the PR's changed files are dropped.
    public static func files(keyAreas: [KeyArea], pendingPaths: [String], changed: [String]) -> [FocusFile] {
        let changed = Set(changed)
        var order: [String] = []
        var areas: [String: [KeyArea]] = [:]
        for area in keyAreas where changed.contains(area.path) {
            if areas[area.path] == nil { order.append(area.path) }
            areas[area.path, default: []].append(area)
        }
        let pending = Dictionary(grouping: pendingPaths.filter(changed.contains), by: { $0 }).mapValues(\.count)
        order += pending.keys.filter { areas[$0] == nil }.sorted()
        return order.map { FocusFile(path: $0, areas: areas[$0] ?? [], pendingComments: pending[$0] ?? 0) }
    }

    /// Every key area in reading order, the one list Focus walks and Risk groups by question. `index` is the area's
    /// position in its file's `areas`, which selects it in Changes.
    public static func readingList(_ files: [FocusFile]) -> [(path: String, index: Int, area: KeyArea)] {
        files.flatMap { file in file.areas.indices.map { (path: file.path, index: $0, area: file.areas[$0]) } }
    }

    /// The next unread key area in reading order (the Focus list's), after `current` and wrapping around to the
    /// start; nil when every area is read. `index` is the area's position in its file's `areas`.
    public static func nextUnread(_ files: [FocusFile], isRead: (KeyArea) -> Bool,
                                  after current: (path: String, index: Int)?) -> (path: String, index: Int)? {
        let all = readingList(files)
        let start = current.flatMap { current in all.firstIndex { $0.path == current.path && $0.index == current.index } }.map { $0 + 1 } ?? 0
        return (all[start...] + all[..<start]).first { !isRead($0.area) }.map { ($0.path, $0.index) }
    }

    /// Where stepping through key areas goes past either end of `path`'s: the first area of the next file in the list
    /// that has some, or the last area of the previous one. A file outside the list starts from the list's first (or
    /// last) file with areas. Nil past either end of the list.
    public static func area(beyond path: String, in files: [FocusFile], forward: Bool) -> (path: String, index: Int)? {
        let current = files.firstIndex { $0.path == path }
        let candidates = (current.map { forward ? files[($0 + 1)...] : files[..<$0] } ?? files[...]).filter { !$0.areas.isEmpty }
        guard let file = forward ? candidates.first : candidates.last else { return nil }
        return (file.path, forward ? 0 : file.areas.count - 1)
    }
}

extension Focus {
    /// One PR's read marks (area key → head it was read at) after marking `key` read or unread at `head`. Marks
    /// from older heads are dropped: a push makes every area unread again, so they'd never count.
    public static func readMarks(_ marks: [String: String], setting key: String, read: Bool, head: String) -> [String: String] {
        var marks = marks.filter { $0.value == head }
        marks[key] = read ? head : nil
        return marks
    }
}

extension KeyArea {
    /// Names the area in the saved read state: its file and lines, which a reworded reason doesn't change.
    public var readKey: String {
        "\(path):\(startLine.map(String.init) ?? "file")-\(endLine.map(String.init) ?? ""):\(risk ?? "")"
    }
}
