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
