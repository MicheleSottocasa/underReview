import Foundation

public enum AIEngine: Codable, Hashable, Sendable {
    case claudeCode
    case codex
    case ollama(model: String)
    /// A running Claude Code session linked to the PR: the review starts from its conversation.
    case claudeSession(id: String, name: String, cwd: String)

    public var tool: String {
        switch self {
        case .claudeCode, .claudeSession: "claude"
        case .codex: "codex"
        case .ollama: "ollama"
        }
    }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeSession(_, let name, _): "Claude Code · \(name)"
        case .codex: "Codex"
        case .ollama(let model): "Ollama (\(model))"
        }
    }

    /// Cloud engines send the code to their provider; Ollama stays on this Mac.
    public var isLocal: Bool { if case .ollama = self { true } else { false } }
}

public enum AIError: Error, LocalizedError, Equatable {
    case notLoggedIn(String)
    case notSubscription(String)
    case invalidOutput(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn(let detail): "Not logged in: \(detail)"
        case .notSubscription(let detail): "Refusing to run: \(detail). Log in with your subscription so no API billing is used."
        case .invalidOutput(let detail): "The model returned output that isn't a valid review: \(detail)"
        case .failed(let detail): detail
        }
    }
}

/// A stored AI review. Findings stay local until the user accepts them as drafts.
public struct AIRun: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var prID: String
    public var engine: AIEngine
    /// Head the review was run on; a newer head makes the result outdated.
    public var headRefOid: String
    public var date = Date()
    public var result: ReviewResult
    /// Indexes of findings already turned into drafts or dismissed.
    public var handled: Set<Int> = []

    public init(prID: String, engine: AIEngine, headRefOid: String, result: ReviewResult) {
        (self.prID, self.engine, self.headRefOid, self.result) = (prID, engine, headRefOid, result)
    }
}

/// Runs reviews through the official CLIs with their own login. Tools, hooks, plugins and MCP are off,
/// the working directory is empty, and API-key env vars are stripped by `ProcessRunner`.
public struct AIReviewer: Sendable {
    public let runner: any CommandRunner

    public init(runner: any CommandRunner) { self.runner = runner }

    public func checkAuth(_ engine: AIEngine) async throws {
        switch engine {
        case .claudeCode, .claudeSession:
            let status = try await runner.run("claude", ["auth", "status", "--json"])
            let json = (try? JSONSerialization.jsonObject(with: status.stdout)) as? [String: Any]
            guard json?["loggedIn"] as? Bool == true else { throw AIError.notLoggedIn("run `claude auth login`") }
            let method = json?["authMethod"] as? String ?? "unknown"
            guard method == "claude.ai" else { throw AIError.notSubscription("Claude Code is authenticated via \(method)") }
        case .codex:
            let status = try await runner.run("codex", ["login", "status"])
            let text = status.text + status.stderr
            guard status.status == 0 else { throw AIError.notLoggedIn("run `codex login`") }
            guard text.contains("ChatGPT") else { throw AIError.notSubscription(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        case .ollama:
            let status = try await runner.run("ollama", ["list"])
            guard status.status == 0 else { throw AIError.failed("Ollama isn't running: \(status.stderr)") }
        }
    }

    public func review(_ engine: AIEngine, prompt: String, timeout: Duration = .seconds(600)) async throws -> ReviewResult {
        try await checkAuth(engine)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reviewdesk-ai-\(UUID().uuidString)")
        let workdir = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = Data(prompt.utf8)

        switch engine {
        case .claudeCode:
            let result = try await runner.run("claude", [
                "-p", "--output-format", "json", "--json-schema", AIContext.schema,
                "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                "--disable-slash-commands", "--no-session-persistence",
            ], stdin: input, cwd: workdir, timeout: timeout)
            return try Self.parseClaude(result)

        case .claudeSession(let id, _, let cwd):
            // Fork without saving: the review reuses the agent's context but never writes back into its
            // session, and running in its folder is how Claude Code finds the session. Tools stay off,
            // so the user's checkout is only ever read through the context we send.
            let result = try await runner.run("claude", [
                "-p", "--resume", id, "--fork-session", "--no-session-persistence",
                "--output-format", "json", "--json-schema", AIContext.schema,
                "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
            ], stdin: input, cwd: URL(fileURLWithPath: cwd), timeout: timeout)
            return try Self.parseClaude(result)

        case .codex:
            let schema = dir.appendingPathComponent("schema.json"), output = dir.appendingPathComponent("last.json")
            try Data(AIContext.schema.utf8).write(to: schema)
            let result = try await runner.run("codex", [
                "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
                "--ignore-user-config", "--ignore-rules", "--disable", "hooks", "--disable", "plugins",
                "--output-schema", schema.path, "-o", output.path, "-C", workdir.path, "-",
            ], stdin: input, cwd: workdir, timeout: timeout)
            guard result.status == 0 else { throw AIError.failed(Self.tail(result.stderr)) }
            return try Self.decode((try? Data(contentsOf: output)) ?? Data())

        case .ollama(let model):
            let result = try await runner.run("ollama", ["run", model, "--format", "json", "--hidethinking"], stdin: input, cwd: workdir, timeout: timeout)
            guard result.status == 0 else { throw AIError.failed(Self.tail(result.stderr)) }
            return try Self.decode(result.stdout)
        }
    }

    static func parseClaude(_ result: CommandResult) throws -> ReviewResult {
        guard let json = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] else {
            throw AIError.failed(tail(result.stderr.isEmpty ? result.text : result.stderr))
        }
        if json["is_error"] as? Bool == true || result.status != 0 {
            // Expired login and plan limits arrive here as the result text.
            throw AIError.failed(json["result"] as? String ?? tail(result.stderr))
        }
        if let structured = json["structured_output"] {
            return try decode(JSONSerialization.data(withJSONObject: structured))
        }
        return try decode(Data((json["result"] as? String ?? "").utf8))
    }

    static func decode(_ data: Data) throws -> ReviewResult {
        do {
            return try JSONDecoder().decode(ReviewResult.self, from: data)
        } catch {
            throw AIError.invalidOutput(String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    static func tail(_ text: String) -> String {
        text.split(separator: "\n").suffix(5).joined(separator: "\n")
    }
}
