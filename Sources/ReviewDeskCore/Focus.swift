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
}
