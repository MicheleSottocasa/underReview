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
        return entries.compactMap { entry in
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

    /// Agents whose working folder is named like the PR's repo come first.
    // ponytail: folder-name match, not the git remote; check `git remote` if repos get renamed locally.
    public static func sorted(_ agents: [RunningAgent], for repo: String) -> [RunningAgent] {
        agents.sorted { (isLikely($0, repo: repo) ? 0 : 1, $0.name) < (isLikely($1, repo: repo) ? 0 : 1, $1.name) }
    }

    public static func isLikely(_ agent: RunningAgent, repo: String) -> Bool {
        guard let name = repo.split(separator: "/").last else { return false }
        return URL(fileURLWithPath: agent.cwd).pathComponents.contains(String(name))
    }
}
