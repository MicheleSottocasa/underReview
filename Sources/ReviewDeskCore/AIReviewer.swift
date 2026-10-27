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
        case .notSubscription(let detail):
            "Refusing to run: \(detail). Log in with your subscription, or use workload identity federation for Claude Code, so no API key is used."
        case .invalidOutput(let detail): "The model returned output that isn't a valid review: \(detail)"
        case .failed(let detail): detail
        }
    }
}

/// The model and effort an engine runs with, picked per provider. "" keeps the CLI's own default, so an update that
/// changes it keeps working. Claude Code's effort is also `/code-review`'s level; Ollama's is how much the model thinks.
/// Ollama's model is part of its engine, so `model` is unused there.
public struct AIOptions: Codable, Hashable, Sendable {
    public var model: String
    public var effort: String

    public init(model: String = "", effort: String = "high") {
        (self.model, self.effort) = (model, effort)
    }

    /// The efforts `engine` takes, lowest first. Claude Code always gets one (`/code-review` needs a level);
    /// Codex and Ollama may keep their default ("").
    public static func efforts(for engine: AIEngine) -> [String] {
        switch engine {
        case .claudeCode, .claudeSession: ["low", "medium", "high", "xhigh", "max"]
        case .codex: ["minimal", "low", "medium", "high"]
        case .ollama: ["off", "low", "medium", "high"]
        }
    }

    /// The models offered for `engine` besides Default and *Other…*. Ollama's come from `ollama list` instead.
    /// For Claude Code: the family aliases, which follow each new version, then pinned versions.
    // ponytail: neither CLI has a command that lists its models, so these are a short curated list; Other… takes any id.
    public static func models(for engine: AIEngine) -> [ModelChoice] {
        switch engine {
        case .claudeCode, .claudeSession:
            [ModelChoice("fable", "Fable"), ModelChoice("opus", "Opus"), ModelChoice("sonnet", "Sonnet"), ModelChoice("haiku", "Haiku"),
             ModelChoice("claude-opus-5-5", "Opus 5.5"), ModelChoice("claude-sonnet-5-5", "Sonnet 5.5"),
             ModelChoice("claude-haiku-5-5", "Haiku 5.5"), ModelChoice("claude-fable-5-1", "Fable 5.1")]
        case .codex: [ModelChoice("gpt-5-codex", "GPT-5 Codex"), ModelChoice("gpt-5", "GPT-5")]
        case .ollama: []
        }
    }

    /// The CLI flags for `engine`; a default passes nothing. Only listed efforts go through, and a model that could
    /// read as a flag (or holds spaces) is dropped, so nothing typed under *Other…* can add an option of its own.
    public func arguments(for engine: AIEngine) -> [String] {
        let model = Self.isModelName(model) ? model : ""
        let effort = Self.efforts(for: engine).contains(effort) ? effort : ""
        switch engine {
        case .claudeCode, .claudeSession:
            return (model.isEmpty ? [] : ["--model", model]) + (effort.isEmpty ? [] : ["--effort", effort])
        case .codex:
            // We run with --ignore-user-config, so config.toml can't set the effort: it goes as an override.
            return (model.isEmpty ? [] : ["--model", model]) + (effort.isEmpty ? [] : ["-c", "model_reasoning_effort=\(effort)"])
        case .ollama:
            return effort.isEmpty ? [] : ["--think=\(effort == "off" ? "false" : effort)"]
        }
    }

    /// Claude Code's suffix on a model for its 1M-token context window (`opus[1m]`).
    public static let longContextSuffix = "[1m]"

    /// `model` with the 1M-token context window when `longContext` is on. Default stays "", since the suffix needs a
    /// model to go on, and an id typed with the suffix under *Other…* keeps it.
    public static func claudeModel(_ model: String, longContext: Bool) -> String {
        guard longContext, !model.isEmpty, !model.hasSuffix(longContextSuffix) else { return model }
        return model + longContextSuffix
    }

    /// How a run used them, for its card and Re-run: "Opus · high", "Opus 5.5 · 1M context · max",
    /// "GPT-5 Codex · default effort", "low thinking".
    public func label(for engine: AIEngine) -> String {
        if case .ollama = engine {
            return effort.isEmpty ? "default thinking" : effort == "off" ? "no thinking" : "\(effort) thinking"
        }
        let long = engine.tool == "claude" && model.hasSuffix(Self.longContextSuffix)
        let base = long ? String(model.dropLast(Self.longContextSuffix.count)) : model
        let name = (base.isEmpty ? "default model" : Self.models(for: engine).first { $0.id == base }?.label ?? base)
            + (long ? " · 1M context" : "")
        // Claude Code's other calls (its runs on ReviewDesk's prompt among them) keep the CLI's effort: no level to name.
        if engine.tool == "claude" { return effort.isEmpty ? name : "\(name) · \(effort)" }
        return "\(name) · \(effort.isEmpty ? "default" : effort) effort"
    }

    /// A model id or alias: letters, digits and `.-_:/[]`, not starting with `-`.
    static func isModelName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-:/[]".contains($0)) }
    }
}

/// A provider's CLI as Settings › AI shows it.
public struct ProviderStatus: Equatable, Sendable {
    /// Nil when the CLI isn't installed or didn't say.
    public var version: String?
    /// How it's logged in, or why it can't run.
    public var detail: String
    public var isReady: Bool

    public init(version: String?, detail: String, isReady: Bool) {
        (self.version, self.detail, self.isReady) = (version, detail, isReady)
    }
}

/// A model in a picker: the id passed to the CLI, and its name.
public struct ModelChoice: Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String

    public init(_ id: String, _ label: String) { (self.id, self.label) = (id, label) }
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
    /// The model and effort it ran with; nil for Codex and Ollama runs saved before they had a choice.
    public var options: AIOptions?
    /// What the run used, when its CLI reported it; nil for runs saved before ReviewDesk recorded usage.
    public var usage: TokenUsage?
    /// The estimate shown before running (the input the app sent), kept to calibrate later estimates against `usage`.
    public var estimatedTokens: Int?
    /// The review command it ran (`ReviewCommand.label`); nil for runs saved before there was a choice, which were
    /// `/code-review` with Claude Code and ReviewDesk's prompt otherwise.
    public var command: String?
    /// Indexes of findings already turned into drafts or dismissed.
    public var handled: Set<Int> = []

    public init(prID: String, engine: AIEngine, headRefOid: String, result: ReviewResult) {
        (self.prID, self.engine, self.headRefOid, self.result) = (prID, engine, headRefOid, result)
    }

    /// The author pushed since this run: its findings, key areas and line numbers may no longer match the code.
    /// An unknown head (GitHub returned none) isn't a push.
    public func isOutdated(for pr: PullRequest) -> Bool { !pr.headRefOid.isEmpty && headRefOid != pr.headRefOid }

    /// The command's name for the run's card; nil for ReviewDesk's own prompt.
    public var commandLabel: String? {
        let generic = ReviewCommand.generic.label(saved: [])
        let name = command ?? (engine.tool == "claude" ? ReviewCommand.codeReview.label(saved: []) : generic)
        return name == generic ? nil : name
    }

    /// A Claude Code `/code-review`, whose usage calibrates the next one's estimate.
    public var ranCodeReview: Bool { engine.tool == "claude" && commandLabel == ReviewCommand.codeReview.label(saved: []) }

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
    /// How Claude Code signs in (Settings › AI), the same the runner passes to it.
    public let claudeSignIn: @Sendable () -> ClaudeSignIn

    public init(runner: any CommandRunner, claudeConfigDirectory: URL = ClaudeSessionFiles.defaultConfigDirectory,
                claudeSignIn: @escaping @Sendable () -> ClaudeSignIn = { ClaudeSignIn() }) {
        self.runner = runner
        self.claudeConfigDirectory = claudeConfigDirectory
        self.claudeSignIn = claudeSignIn
    }

    public func checkAuth(_ engine: AIEngine) async throws {
        switch engine {
        case .claudeCode, .claudeSession:
            let signIn = claudeSignIn()
            if let problem = signIn.problem() { throw AIError.notLoggedIn(problem) }
            let status = try await runner.run("claude", ["auth", "status", "--json"])
            let json = (try? JSONSerialization.jsonObject(with: status.stdout)) as? [String: Any]
            let method = json?["authMethod"] as? String ?? "unknown"
            switch signIn.method {
            case .subscription:
                guard json?["loggedIn"] as? Bool == true else { throw AIError.notLoggedIn("run `claude auth login`") }
                guard method == "claude.ai" else { throw AIError.notSubscription("Claude Code is authenticated via \(method)") }
            case .federation:
                // The token is exchanged on each run, so there may be no stored login to report: only a key is refused.
                guard !ClaudeSignIn.isAPIKey(method) else { throw AIError.notSubscription("Claude Code is authenticated via \(method)") }
            }
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

    /// Its CLI's version and whether it's ready to run (logged in with a subscription, or Ollama running), for
    /// Settings › AI. Runs only the version and login checks, never a model.
    public func status(_ engine: AIEngine) async -> ProviderStatus {
        let output = try? await runner.run(engine.tool, ["--version"])
        let version = output.flatMap { Self.version($0.text + "\n" + $0.stderr) }
        do {
            try await checkAuth(engine)
            switch engine {
            case .claudeCode, .claudeSession:
                let signIn = claudeSignIn()
                guard signIn.method == .subscription else {
                    let profile = signIn.profile.isEmpty ? "" : " (profile \(signIn.profile))"
                    return ProviderStatus(version: version, detail: "Signs in with workload identity federation\(profile)", isReady: true)
                }
                return ProviderStatus(version: version, detail: "Logged in with your Claude subscription", isReady: true)
            case .codex:
                return ProviderStatus(version: version, detail: "Logged in with ChatGPT", isReady: true)
            case .ollama:
                let count = await ollamaModels().count
                return ProviderStatus(version: version, detail: "Running, \(count) model\(count == 1 ? "" : "s") pulled", isReady: true)
            }
        } catch {
            return ProviderStatus(version: version, detail: error.localizedDescription, isReady: false)
        }
    }

    /// The version number in a CLI's `--version` output: "2.1.3 (Claude Code)", "codex-cli 0.46.0",
    /// "ollama version is 0.12.3" (or, with Ollama stopped, "Warning: client version is 0.12.3").
    static func version(_ output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).first { $0.first?.isNumber == true && $0.contains(".") }.map(String.init)
    }

    /// The models Ollama has pulled, by name (`qwen2.5-coder:latest`); empty when it isn't running.
    public func ollamaModels() async -> [String] {
        guard let list = try? await runner.run("ollama", ["list"]), list.status == 0 else { return [] }
        return Self.ollamaModels(list: list.text)
    }

    /// The first column of `ollama list`, below its header.
    static func ollamaModels(list: String) -> [String] {
        list.split(separator: "\n").dropFirst().compactMap { $0.split(separator: " ").first.map(String.init) }
    }

    /// Whether `model` can think, so its thinking level can be picked; false when Ollama can't tell.
    public func ollamaThinks(_ model: String) async -> Bool {
        guard AIOptions.isModelName(model), let show = try? await runner.run("ollama", ["show", model]), show.status == 0 else { return false }
        return Self.ollamaThinks(show: show.text)
    }

    /// `ollama show` lists "thinking" in the model's Capabilities section when it supports `--think`.
    static func ollamaThinks(show: String) -> Bool {
        let lines = show.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(of: "Capabilities") else { return false }
        return lines[(start + 1)...].prefix { !$0.isEmpty }.contains("thinking")
    }

    /// `usage` collects what each CLI call reported, when the caller wants to show it.
    /// `options` are the provider's model and effort; nil runs on the CLI's defaults.
    public func review(_ engine: AIEngine, prompt: String, options: AIOptions? = nil, timeout: Duration = .seconds(600),
                       usage: UsageMeter? = nil) async throws -> ReviewResult {
        try Self.decode(try await run(engine, prompt: prompt, schema: AIContext.schema, options: options, timeout: timeout, usage: usage))
    }

    /// Claude Code's own `/code-review` on the PR, then a quick tool-less pass that turns its report into findings
    /// and key areas (the command runs in its own agent, so it can't return the app's JSON itself).
    /// The review gets read-only tools only: file reading in its working directory and `gh pr diff` / `gh pr view`.
    /// Anything else, including every write, is denied without asking, and `instructions` forbid posting to GitHub.
    /// `context` holds the PR's diffs (no full files) for picking key areas. `folders` are the project's reference
    /// folders: added with `--add-dir`, so the same read-only file tools can read them (restricted mode confines
    /// file tools to the working directory and these). `checkout` is the pull request's files at its head commit
    /// (`LocalClone.snapshot`), added the same way. Without one, or without being told there is none, the command tries to
    /// clone or search the disk.
    public func codeReview(_ engine: AIEngine, prURL: String, context: ReviewContext, options: AIOptions,
                           folders: [String] = [], checkout: String? = nil,
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
        // Fixed rules, after the editable instructions so a custom prompt can't drop them. The review itself runs in a
        // helper agent that sees neither the appended prompt nor a CLAUDE.md, and whose prompt is the command's own
        // (checked live): only the command's arguments reach it, as its review target, so the rules go there too.
        // Untold, it `cd`s into the checkout to run git, pipes or redirects `gh pr diff`, or looks for
        // ~/.claude/CLAUDE.md, and each attempt is refused. No backticks or `--` words: the command would read
        // `--fix`, `--comment` or `--post` there as flags.
        let source = checkout.map { "The pull request's files, at its head commit, are in \($0): treat them as plain files "
            + "(git can't run there) and read them with your file tools for context around the change." }
            ?? "There is no checkout of the repository: review from gh pr diff and gh pr view."
        let limits = "Don't run git, clone, check out or fetch anything, and don't look for files (CLAUDE.md included) "
            + "outside the folders named here. The only commands that run are gh pr diff and gh pr view, each on its own: "
            + "cd, other commands, pipes, redirections, && and ; are refused. Read a long output that was saved to a file "
            + "with your file tools."
        let reference = folders.isEmpty ? "" : " The reviewer attached reference folders to this project (documentation, related code); "
            + "read them with your file tools when they help you understand the change. They are not part of the pull request: "
            + folders.joined(separator: ", ")
        let rules = source + " " + limits + reference
        let folders = (checkout.map { [$0] } ?? []) + folders
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--forward-subagent-text",
                    "--append-system-prompt", instructions + "\n\n" + rules,
                    "--restricted", "--strict-mcp-config", "--permission-prompts", "none",
                    "--tools", Self.codeReviewTools, "--allowedTools", Self.codeReviewAllowed]
        for folder in folders { args += ["--add-dir", folder] }
        // Hidden files and folders (.env, .git…) stay unreadable in the added folders: deny rules beat the allow
        // list, and Claude Code applies Read rules to Grep and Glob too. `//` starts an absolute path in a rule.
        if !folders.isEmpty { args += ["--disallowedTools"] + folders.flatMap(Self.hiddenFileRules) }
        args += options.arguments(for: .claudeCode)
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
            result = try await runner.stream("claude", args, stdin: Data("/code-review \(options.effort) \(prURL) (ReviewDesk: \(rules))".utf8),
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
        if !diff.happened {
            // Live, only the stream and the first helper's transcript are watched, as they're written: a diff read by a
            // nested or later agent, or in a transcript that appeared just as the run ended, is missed. Before the run's
            // files are removed, read every transcript it left: the whole folder of our own temporary directory, or only
            // the forked session's files in a linked session's folder.
            let transcripts = resumed == nil ? ClaudeSessionFiles.transcripts(in: project)
                : live.session.map { ClaudeSessionFiles(projectDirectory: project, session: $0).transcripts } ?? []
            transcripts.forEach(diff.scan)
        }
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
        return try Self.decode(try await run(.claudeCode, prompt: prompt, schema: AIContext.schema,
                                             options: AIOptions(model: options.model, effort: ""), timeout: .seconds(300), usage: usage))
    }

    /// Codex's own review flow (`codex exec review`) on `prompt` (`AIContext.codexReviewPrompt`), then the same
    /// tool-less pass that turns `/code-review`'s report into findings and key areas. Both calls run like every Codex
    /// call: read-only sandbox, an empty folder, and the user's config, rules, hooks and plugins off.
    public func codexReview(prompt: String, context: ReviewContext, options: AIOptions? = nil,
                            structureInstructions: String = AIContext.defaultStructureInstructions,
                            timeout: Duration = .seconds(1200), usage: UsageMeter? = nil) async throws -> ReviewResult {
        let report = String(decoding: try await run(.codex, prompt: prompt, schema: nil, options: options, timeout: timeout,
                                                    usage: usage, codexReview: true), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !report.isEmpty else { throw AIError.invalidOutput("Codex's review returned no report") }
        let structure = AIContext.structurePrompt(report: report, context: context.fittingBudget(), instructions: structureInstructions,
                                                  source: "Codex's review")
        return try Self.decode(try await run(.codex, prompt: structure, schema: AIContext.schema,
                                             options: AIOptions(model: options?.model ?? "", effort: ""), timeout: .seconds(300), usage: usage))
    }

    /// Permission rules denying hidden files and everything under hidden folders inside `folder` (an absolute path).
    static func hiddenFileRules(_ folder: String) -> [String] {
        ["Read(/\(folder)/**/.*)", "Read(/\(folder)/**/.*/**)"]
    }

    static let codeReviewTools = "Read,Grep,Glob,Bash,Agent"
    static let codeReviewAllowed = "Read,Grep,Glob,Agent,Bash(gh pr diff:*),Bash(gh pr view:*)"

    /// A JSON answer matching `schema`, decoded as `T`, under the same restrictions as a review.
    public func structured<T: Decodable>(_ engine: AIEngine, prompt: String, schema: String, as type: T.Type, options: AIOptions? = nil,
                                         timeout: Duration = .seconds(600), usage: UsageMeter? = nil) async throws -> T {
        let data = try await run(engine, prompt: prompt, schema: schema, options: options, timeout: timeout, usage: usage)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIError.invalidOutput(String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    /// A free-text answer in Markdown, under the same restrictions as a review.
    public func ask(_ engine: AIEngine, prompt: String, options: AIOptions? = nil, timeout: Duration = .seconds(300),
                    usage: UsageMeter? = nil) async throws -> String {
        let answer = String(decoding: try await run(engine, prompt: prompt, schema: nil, options: options, timeout: timeout, usage: usage), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw AIError.invalidOutput("empty answer") }
        return answer
    }

    /// Runs the CLI and returns its answer: JSON matching `schema` when one is given, otherwise text.
    /// `codexReview` runs Codex's `review` subcommand instead of a plain prompt, with the same flags.
    private func run(_ engine: AIEngine, prompt: String, schema: String?, options: AIOptions? = nil, timeout: Duration,
                     usage: UsageMeter? = nil, codexReview: Bool = false) async throws -> Data {
        let chosen = options?.arguments(for: engine) ?? []
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
            ] + Self.claudeSchema(schema) + chosen, stdin: input, cwd: workdir, timeout: timeout)
            usage?.add(Self.claudeUsage(result.stdout))
            return try Self.parseClaude(result)

        case .claudeSession(let id, _, let cwd):
            // Fork without saving: the review reuses the agent's context but never writes back into its
            // session, and running in its folder is how Claude Code finds the session. Tools stay off,
            // so the user's checkout is only ever read through the context we send.
            let result = try await runner.run("claude", [
                "-p", "--resume", id, "--fork-session", "--no-session-persistence", "--output-format", "json",
                "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
            ] + Self.claudeSchema(schema) + chosen, stdin: input, cwd: URL(fileURLWithPath: cwd), timeout: timeout)
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
            // ponytail: `review` goes after exec's own flags, so the sandbox and every override apply to it too. Not
            // checked against each Codex version: one that refuses it fails with its message, and ReviewDesk's prompt
            // (Settings › AI) still works.
            var args = [
                "exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
                "--ignore-user-config", "--ignore-rules", "--disable", "hooks", "--disable", "plugins",
            ]
            args += schemaArgs + chosen + ["-o", output.path, "-C", workdir.path]
            if codexReview { args.append("review") }
            args.append("-")
            let result = try await runner.run("codex", args, stdin: input, cwd: workdir, timeout: timeout)
            // With --json, Codex reports a failed turn (expired login, usage limit, unknown model) as an event on
            // stdout, often with nothing on stderr.
            let error = Self.codexError(events: result.text)
            guard result.status == 0 else { throw AIError.failed(error ?? Self.tail(result.stderr)) }
            usage?.add(TokenUsage.codex(events: result.text))
            guard let answer = try? Data(contentsOf: output) else {
                throw error.map(AIError.failed) ?? AIError.invalidOutput("Codex wrote no answer")
            }
            return answer

        case .ollama(let model):
            let format = schema == nil ? [] : ["--format", "json"]
            // --verbose adds the token counts to stderr; the answer on stdout is unchanged.
            let result = try await runner.run("ollama", ["run", model] + format + chosen + ["--hidethinking", "--verbose"], stdin: input, cwd: workdir, timeout: timeout)
            guard result.status == 0 else { throw AIError.failed(Self.tail(result.stderr)) }
            usage?.add(TokenUsage.ollama(stderr: result.stderr))
            return result.stdout
        }
    }

    /// The last error in `codex exec --json` events: an `error` event's message, or a failed turn's.
    static func codexError(events: String) -> String? {
        var message: String?
        for line in events.split(separator: "\n") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "error": message = event["message"] as? String ?? message
            case "turn.failed": message = (event["error"] as? [String: Any])?["message"] as? String ?? message
            default: break
            }
        }
        return message
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
