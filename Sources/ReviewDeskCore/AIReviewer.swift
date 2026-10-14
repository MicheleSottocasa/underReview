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

/// How Claude Code runs `/code-review`: the model ("" keeps the CLI default) and the effort level.
public struct CodeReviewOptions: Codable, Hashable, Sendable {
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    public var model: String
    public var effort: String

    public init(model: String = "", effort: String = "high") {
        (self.model, self.effort) = (model, effort)
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
    /// Set when Claude Code ran `/code-review`.
    public var options: CodeReviewOptions?
    /// Indexes of findings already turned into drafts or dismissed.
    public var handled: Set<Int> = []

    public init(prID: String, engine: AIEngine, headRefOid: String, result: ReviewResult) {
        (self.prID, self.engine, self.headRefOid, self.result) = (prID, engine, headRefOid, result)
    }

    /// The author pushed since this run: its findings, key areas and line numbers may no longer match the code.
    /// An unknown head (GitHub returned none) isn't a push.
    public func isOutdated(for pr: PullRequest) -> Bool { !pr.headRefOid.isEmpty && headRefOid != pr.headRefOid }

    /// What the stale-analysis banner says; `commits` is nil when GitHub couldn't count them (e.g. after a force-push).
    public func outdatedMessage(for pr: PullRequest, commits: Int?) -> String {
        let pushed = commits.map { "\($0) commit\($0 == 1 ? "" : "s")" } ?? "new commits"
        return "The author pushed \(pushed) since this analysis (\(headRefOid.prefix(7)) → \(pr.headRefOid.prefix(7)))."
    }
}

/// Runs reviews through the official CLIs with their own login. Tools, hooks, plugins and MCP are off,
/// the working directory is empty, and API-key env vars are stripped by `ProcessRunner`.
public struct AIReviewer: Sendable {
    public let runner: any CommandRunner
    /// Where Claude Code keeps sessions: read to follow `/code-review` live, cleaned after each run.
    public let claudeConfigDirectory: URL

    public init(runner: any CommandRunner, claudeConfigDirectory: URL = ClaudeSessionFiles.defaultConfigDirectory) {
        self.runner = runner
        self.claudeConfigDirectory = claudeConfigDirectory
    }

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

    /// `usage` collects what each CLI call reported, when the caller wants to show it.
    public func review(_ engine: AIEngine, prompt: String, timeout: Duration = .seconds(600), usage: UsageMeter? = nil) async throws -> ReviewResult {
        try Self.decode(try await run(engine, prompt: prompt, schema: AIContext.schema, timeout: timeout, usage: usage))
    }

    /// Claude Code's own `/code-review` on the PR, then a quick tool-less pass that turns its report into findings
    /// and key areas (the command runs in its own agent, so it can't return the app's JSON itself).
    /// The review gets read-only tools only: file reading in its working directory and `gh pr diff` / `gh pr view`.
    /// Anything else, including every write, is denied without asking, and `instructions` forbid posting to GitHub.
    /// `context` holds the PR's diffs (no full files) for picking key areas. `folders` are the project's reference
    /// folders: added with `--add-dir`, so the same read-only file tools can read them (restricted mode confines
    /// file tools to the working directory and these).
    public func codeReview(_ engine: AIEngine, prURL: String, context: ReviewContext, options: CodeReviewOptions,
                           folders: [String] = [],
                           instructions: String = AIContext.defaultCodeReviewInstructions,
                           structureInstructions: String = AIContext.defaultStructureInstructions,
                           timeout: Duration = .seconds(1800), usage: UsageMeter? = nil,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ReviewResult {
        try await checkAuth(engine)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reviewdesk-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Streamed so `progress` can show each step. The session is persisted (unlike other runs) because the
        // command's helper agent only writes its transcript, which we follow live, for persisted sessions;
        // the files are removed again below.
        let reference = folders.isEmpty ? "" : "\n\nThe reviewer attached reference folders to this project (documentation, related code); "
            + "read them with your file tools when they help you understand the change. They are not part of the pull request: "
            + folders.joined(separator: ", ")
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--forward-subagent-text",
                    "--append-system-prompt", instructions + reference, "--effort", options.effort,
                    "--restricted", "--strict-mcp-config", "--permission-prompts", "none",
                    "--tools", Self.codeReviewTools, "--allowedTools", Self.codeReviewAllowed]
        for folder in folders { args += ["--add-dir", folder] }
        // Hidden files and folders (.env, .git…) stay unreadable in the added folders: deny rules beat the allow
        // list, and Claude Code applies Read rules to Grep and Glob too. `//` starts an absolute path in a rule.
        if !folders.isEmpty { args += ["--disallowedTools"] + folders.flatMap(Self.hiddenFileRules) }
        if !options.model.isEmpty { args += ["--model", options.model] }
        var cwd = dir
        var resumed: String?
        switch engine {
        case .claudeCode: break
        case .claudeSession(let id, _, let path):
            // Forked, like `review`: the session's context helps, its history stays untouched.
            args += ["--resume", id, "--fork-session"]
            cwd = URL(fileURLWithPath: path)
            resumed = id
        case .codex, .ollama:
            throw AIError.failed("/code-review is a Claude Code command")
        }
        progress("Starting /code-review (\(options.effort))…")
        let started = Date()
        let live = LiveReview()
        let diff = DiffRead()
        let project = ClaudeSessionFiles.projectDirectory(configDirectory: claudeConfigDirectory, cwd: cwd)
        defer {
            if resumed == nil {
                // Our own temporary folder: its whole project entry in Claude Code belongs to this run.
                try? FileManager.default.removeItem(at: project)
            } else if let session = live.session, session != resumed {
                // The linked session's real folder: only files this run created, never the session it forked.
                ClaudeSessionFiles(projectDirectory: project, session: session).remove(createdSince: started)
            }
        }
        var result: CommandResult
        do {
            result = try await runner.stream("claude", args, stdin: Data("/code-review \(options.effort) \(prURL)".utf8),
                                             cwd: cwd, timeout: timeout) { line in
                diff.observe(line)
                if let task = ClaudeActivity.taskStarted(line) {
                    live.start(ClaudeSessionFiles(projectDirectory: project, session: task.session), task: task.task) { line in
                        diff.observe(line)
                        ClaudeActivity.describe(line).forEach(progress)
                    }
                }
                // Once the transcript is followed, the copies Claude Code forwards at the end would repeat it.
                if live.isFollowing, ClaudeActivity.isFromHelper(line) { return }
                ClaudeActivity.describe(line).forEach(progress)
            }
        } catch {
            await live.stop() // a failed or cancelled run must not leave the follower polling
            throw error
        }
        await live.stop()
        if let final = ClaudeActivity.result(in: result.stdout) { result.stdout = final }
        usage?.add(Self.claudeUsage(result.stdout))
        let report = String(decoding: try Self.parseClaude(result), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !report.isEmpty, report != "Command completed" else { throw AIError.invalidOutput("/code-review returned no report") }
        // A review that never saw the diff can only be empty: say so instead of showing it as a clean pull request.
        guard diff.happened else {
            throw AIError.failed("/code-review couldn't read the pull request's diff, so there is no real review. Check that `gh` is installed and logged in (Settings › Tools). It said: \(report.prefix(300))")
        }
        progress("Turning the review into findings, key areas and risk answers…")
        let prompt = AIContext.structurePrompt(report: report, context: context.fittingBudget(), instructions: structureInstructions)
        return try Self.decode(try await run(.claudeCode, prompt: prompt, schema: AIContext.schema, model: options.model, timeout: .seconds(300), usage: usage))
    }

    /// Permission rules denying hidden files and everything under hidden folders inside `folder` (an absolute path).
    static func hiddenFileRules(_ folder: String) -> [String] {
        ["Read(/\(folder)/**/.*)", "Read(/\(folder)/**/.*/**)"]
    }

    static let codeReviewTools = "Read,Grep,Glob,Bash,Agent"
    static let codeReviewAllowed = "Read,Grep,Glob,Agent,Bash(gh pr diff:*),Bash(gh pr view:*)"

    /// A JSON answer matching `schema`, decoded as `T`, under the same restrictions as a review.
    public func structured<T: Decodable>(_ engine: AIEngine, prompt: String, schema: String, as type: T.Type,
                                         timeout: Duration = .seconds(600), usage: UsageMeter? = nil) async throws -> T {
        let data = try await run(engine, prompt: prompt, schema: schema, timeout: timeout, usage: usage)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIError.invalidOutput(String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    /// A free-text answer in Markdown, under the same restrictions as a review.
    public func ask(_ engine: AIEngine, prompt: String, timeout: Duration = .seconds(300), usage: UsageMeter? = nil) async throws -> String {
        let answer = String(decoding: try await run(engine, prompt: prompt, schema: nil, timeout: timeout, usage: usage), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw AIError.invalidOutput("empty answer") }
        return answer
    }

    /// Runs the CLI and returns its answer: JSON matching `schema` when one is given, otherwise text.
    private func run(_ engine: AIEngine, prompt: String, schema: String?, model: String = "", timeout: Duration,
                     usage: UsageMeter? = nil) async throws -> Data {
        try await checkAuth(engine)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reviewdesk-ai-\(UUID().uuidString)")
        let workdir = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Claude Code files even unsaved runs under its projects folder; this entry is unique to the run.
        let project = ClaudeSessionFiles.projectDirectory(configDirectory: claudeConfigDirectory, cwd: workdir)
        defer { if engine == .claudeCode { try? FileManager.default.removeItem(at: project) } }
        let input = Data(prompt.utf8)

        switch engine {
        case .claudeCode:
            let result = try await runner.run("claude", [
                "-p", "--output-format", "json",
                "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                "--disable-slash-commands", "--no-session-persistence",
            ] + Self.claudeSchema(schema) + (model.isEmpty ? [] : ["--model", model]), stdin: input, cwd: workdir, timeout: timeout)
            usage?.add(Self.claudeUsage(result.stdout))
            return try Self.parseClaude(result)

        case .claudeSession(let id, _, let cwd):
            // Fork without saving: the review reuses the agent's context but never writes back into its
            // session, and running in its folder is how Claude Code finds the session. Tools stay off,
            // so the user's checkout is only ever read through the context we send.
            let result = try await runner.run("claude", [
                "-p", "--resume", id, "--fork-session", "--no-session-persistence", "--output-format", "json",
                "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
            ] + Self.claudeSchema(schema), stdin: input, cwd: URL(fileURLWithPath: cwd), timeout: timeout)
            usage?.add(Self.claudeUsage(result.stdout))
            return try Self.parseClaude(result)

        case .codex:
            let output = dir.appendingPathComponent("last.json")
            var schemaArgs: [String] = []
            if let schema {
                let file = dir.appendingPathComponent("schema.json")
                try Data(schema.utf8).write(to: file)
                schemaArgs = ["--output-schema", file.path]
            }
            // --json prints events on stdout, the last one carrying the usage; the answer still goes to `output`.
            let result = try await runner.run("codex", [
                "exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
                "--ignore-user-config", "--ignore-rules", "--disable", "hooks", "--disable", "plugins",
            ] + schemaArgs + ["-o", output.path, "-C", workdir.path, "-"], stdin: input, cwd: workdir, timeout: timeout)
            guard result.status == 0 else { throw AIError.failed(Self.tail(result.stderr)) }
            usage?.add(TokenUsage.codex(events: result.text))
            return (try? Data(contentsOf: output)) ?? Data()

        case .ollama(let model):
            let format = schema == nil ? [] : ["--format", "json"]
            // --verbose adds the token counts to stderr; the answer on stdout is unchanged.
            let result = try await runner.run("ollama", ["run", model] + format + ["--hidethinking", "--verbose"], stdin: input, cwd: workdir, timeout: timeout)
            guard result.status == 0 else { throw AIError.failed(Self.tail(result.stderr)) }
            usage?.add(TokenUsage.ollama(stderr: result.stderr))
            return result.stdout
        }
    }

    static func claudeSchema(_ schema: String?) -> [String] { schema.map { ["--json-schema", $0] } ?? [] }

    /// The usage in Claude Code's JSON result, if it reported one.
    static func claudeUsage(_ stdout: Data) -> TokenUsage? {
        ((try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any]).flatMap(TokenUsage.claude)
    }

    /// The structured output as JSON when a schema was used, otherwise the answer text.
    static func parseClaude(_ result: CommandResult) throws -> Data {
        guard let json = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] else {
            throw AIError.failed(tail(result.stderr.isEmpty ? result.text : result.stderr))
        }
        if json["is_error"] as? Bool == true || result.status != 0 {
            // Expired login and plan limits arrive here as the result text.
            throw AIError.failed(json["result"] as? String ?? tail(result.stderr))
        }
        if let structured = json["structured_output"] {
            return try JSONSerialization.data(withJSONObject: structured)
        }
        return Data((json["result"] as? String ?? "").utf8)
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
