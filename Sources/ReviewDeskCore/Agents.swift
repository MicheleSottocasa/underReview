import Foundation

/// A Claude Code session running on this Mac, as `claude agents --json` reports it.
public struct RunningAgent: Hashable, Identifiable, Sendable {
    public var sessionID: String
    /// Short id that `attach`, `logs` and `stop` take; only background sessions have one.
    public var shortID: String?
    public var name: String
    public var cwd: String
    /// "idle", "working", "blocked", …
    public var status: String
    public var pid: Int?
    /// `owner/repo` of the folder's origin remote, when it's a GitHub checkout.
    public var repo: String?
    /// Last activity, for stored sessions that aren't running.
    public var updatedAt: Date?
    public var branch: String?

    public var id: String { sessionID }
    public var isBackground: Bool { shortID != nil }
}

/// Lists and manages running Claude Code sessions through its CLI.
public struct ClaudeAgents: Sendable {
    public let runner: any CommandRunner

    public init(runner: any CommandRunner) { self.runner = runner }

    public func list() async throws -> [RunningAgent] {
        let data = try await runner.output("claude", ["agents", "--json"])
        let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        var agents: [RunningAgent] = entries.compactMap { entry in
            guard let session = entry["sessionId"] as? String else { return nil }
            let background = entry["kind"] as? String == "background"
            return RunningAgent(
                sessionID: session,
                shortID: background ? entry["id"] as? String : nil,
                name: entry["name"] as? String ?? session,
                cwd: entry["cwd"] as? String ?? "",
                status: (entry["status"] ?? entry["state"]) as? String ?? "unknown",
                pid: entry["pid"] as? Int
            )
        }
        var repos: [String: String?] = [:]
        for index in agents.indices {
            let cwd = agents[index].cwd
            if repos[cwd] == nil { repos[cwd] = await originRepo(of: cwd) }
            agents[index].repo = repos[cwd] ?? nil
        }
        return agents
    }

    /// Recently active stored sessions (running or not), newest first, with their repo resolved.
    /// A stopped session can still be linked: the review resumes it as a fork.
    public func recent(limit: Int = 200, projects: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) async -> [RunningAgent] {
        var sessions = await Task.detached { ClaudeSessions.scan(projects, limit: limit) }.value
        var repos: [String: String?] = [:]
        for index in sessions.indices {
            let cwd = sessions[index].cwd
            if repos[cwd] == nil { repos[cwd] = await originRepo(of: cwd) }
            sessions[index].repo = repos[cwd] ?? nil
        }
        return sessions
    }

    /// `owner/repo` from the folder's origin remote (https or ssh), nil when it isn't a GitHub checkout.
    func originRepo(of folder: String) async -> String? {
        guard !folder.isEmpty, let result = try? await runner.run("git", ["-C", folder, "remote", "get-url", "origin"]),
              result.status == 0 else { return nil }
        return Self.repo(fromRemote: result.text)
    }

    static func repo(fromRemote url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "github.com[:/]", options: .regularExpression) else { return nil }
        var path = String(trimmed[range.upperBound...])
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        return parts.count == 2 ? path : nil
    }

    /// Recent terminal output of a background session.
    public func logs(_ agent: RunningAgent) async throws -> String {
        guard let id = agent.shortID else { return "" }
        return String(decoding: try await runner.output("claude", ["logs", id]), as: UTF8.self)
    }

    /// Stops a background session; its conversation is kept.
    public func stop(_ agent: RunningAgent) async throws {
        guard let id = agent.shortID else { return }
        _ = try await runner.output("claude", ["stop", id])
    }

    /// Only agents working in the PR's repo, those named after the PR number first.
    public static func inScope(_ agents: [RunningAgent], for pr: PRRef) -> [RunningAgent] {
        agents.filter { relevance($0, to: pr) > 0 }.sorted { (-relevance($0, to: pr), $0.name) < (-relevance($1, to: pr), $1.name) }
    }

    /// 0: another repo; 1: the PR's repo; 2: the PR's repo and the session name mentions the PR number.
    public static func relevance(_ agent: RunningAgent, to pr: PRRef) -> Int {
        // ponytail: without a GitHub remote, fall back to a folder named like the repo.
        let sameRepo = agent.repo.map { $0.caseInsensitiveCompare(pr.nameWithOwner) == .orderedSame }
            ?? URL(fileURLWithPath: agent.cwd).pathComponents.contains(pr.repo)
        guard sameRepo else { return 0 }
        return agent.name.split { !$0.isNumber }.contains { Int($0) == pr.number } ? 2 : 1
    }
}

/// Reads Claude Code's stored transcripts (`~/.claude/projects/<folder>/<session>.jsonl`).
// ponytail: this is Claude Code's internal file format and there's no CLI to list past sessions; only the
// head and tail of each file are read. Switch to a CLI listing if one appears.
enum ClaudeSessions {
    static let headBytes = 256 * 1024, tailBytes = 64 * 1024

    static func scan(_ projects: URL, limit: Int) -> [RunningAgent] {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        let files = folders.flatMap { folder in
            ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        var result: [RunningAgent] = []
        for (file, date) in dated where result.count < limit {
            if let session = read(file, updatedAt: date) { result.append(session) }
        }
        return result
    }

    static func read(_ file: URL, updatedAt: Date) -> RunningAgent? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        var data = (try? handle.read(upToCount: headBytes)) ?? Data()
        if size > UInt64(headBytes) {
            try? handle.seek(toOffset: max(UInt64(headBytes), size - UInt64(tailBytes)))
            data.append(Data("\n".utf8))
            data.append((try? handle.readToEnd()) ?? Data())
        }
        var cwd: String?, branch: String?, title: String?, firstPrompt: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue } // cut lines at the seams
            switch entry["type"] as? String {
            case "continued-in": return nil // superseded by a newer session
            case "custom-title": title = entry["customTitle"] as? String ?? title
            case "agent-name": title = title ?? entry["agentName"] as? String
            case "user":
                cwd = cwd ?? entry["cwd"] as? String
                branch = branch ?? entry["gitBranch"] as? String
                if firstPrompt == nil, let text = (entry["message"] as? [String: Any])?["content"] as? String,
                   !text.hasPrefix("<"), !text.isEmpty {
                    firstPrompt = text
                }
            default: break
            }
        }
        guard let cwd else { return nil }
        let session = file.deletingPathExtension().lastPathComponent
        let name = title ?? firstPrompt.map { String($0.prefix(70)).replacingOccurrences(of: "\n", with: " ") } ?? String(session.prefix(8))
        return RunningAgent(sessionID: session, name: name, cwd: cwd, status: "stopped", updatedAt: updatedAt, branch: branch)
    }
}
