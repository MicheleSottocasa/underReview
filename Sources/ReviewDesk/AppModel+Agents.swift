import Foundation
import ReviewDeskCore

/// A Claude Code session linked to a PR. Name and folder are kept so the link still reads well
/// after the session stops; a stopped session can still be resumed for a review.
struct AgentLink: Codable, Hashable {
    var sessionID: String
    var name: String
    var cwd: String

    var engine: AIEngine { .claudeSession(id: sessionID, name: name, cwd: cwd) }
}

extension AppModel {
    func refreshAgents() async {
        await whilePending("agents") {
            do {
                runningAgents = try await agents.list()
            } catch {
                report(error, "Couldn't list Claude Code agents")
            }
            recentSessions = await agents.recent()
        }
    }

    /// Stored sessions in the PR's repo that aren't running: named after the PR first, then newest.
    func recentSessions(for pr: PullRequest, limit: Int = 30) -> [RunningAgent] {
        let running = Set(runningAgents.map(\.sessionID))
        return recentSessions
            .filter { !running.contains($0.sessionID) && ClaudeAgents.relevance($0, to: pr.ref) > 0 }
            .sorted { (ClaudeAgents.relevance($0, to: pr.ref), $0.updatedAt ?? .distantPast) > (ClaudeAgents.relevance($1, to: pr.ref), $1.updatedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func link(_ agent: RunningAgent, to pr: PullRequest) {
        agentLinks[pr.id] = AgentLink(sessionID: agent.sessionID, name: agent.name, cwd: agent.cwd)
    }

    func unlink(_ pr: PullRequest) {
        agentLinks[pr.id] = nil
    }

    /// The live session behind a link, if it's still running.
    func runningAgent(for link: AgentLink) -> RunningAgent? {
        runningAgents.first { $0.sessionID == link.sessionID }
    }

    /// Nil while the agent has another action in flight.
    func logs(_ agent: RunningAgent) async -> String? {
        await whilePending(agent.sessionID) {
            do { return try await agents.logs(agent) } catch { return error.localizedDescription }
        }
    }

    func stop(_ agent: RunningAgent) async {
        await whilePending(agent.sessionID) {
            do { try await agents.stop(agent) } catch { report(error) }
            await refreshAgents()
        }
    }

    /// Background sessions open with `claude attach` in a new Terminal window.
    func openInTerminal(_ agent: RunningAgent) async {
        guard let id = agent.shortID else { return }
        let script = """
        tell application "Terminal"
            activate
            do script "claude attach \(id)"
        end tell
        """
        await whilePending(agent.sessionID) {
            do { _ = try await github.runner.output("osascript", ["-e", script]) } catch { report(error) }
        }
    }
}
