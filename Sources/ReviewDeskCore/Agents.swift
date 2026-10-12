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

    /// Sessions named after the PR number come first, then sessions in a folder named like the PR's repo.
    // ponytail: name and folder-name heuristics, not the git remote; check `git remote` if repos get renamed locally.
    public static func sorted(_ agents: [RunningAgent], for pr: PRRef) -> [RunningAgent] {
        agents.sorted { (-relevance($0, to: pr), $0.name) < (-relevance($1, to: pr), $1.name) }
    }

    /// 2: the session name mentions the PR number; 1: it works in the repo's folder; 0: unrelated.
    public static func relevance(_ agent: RunningAgent, to pr: PRRef) -> Int {
        let numbers = agent.name.split { !$0.isNumber }.compactMap { Int($0) }
        if numbers.contains(pr.number) { return 2 }
        return URL(fileURLWithPath: agent.cwd).pathComponents.contains(pr.repo) ? 1 : 0
    }
}
