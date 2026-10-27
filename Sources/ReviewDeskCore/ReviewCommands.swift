import Foundation

/// What *Review* runs for a provider, picked in Settings › AI. Claude Code and Codex have a review command of their
/// own; Ollama has none, so the user saves review prompts for it. ReviewDesk's own prompt (Settings › Prompts) is the
/// fallback for every provider.
public enum ReviewCommand: Hashable, Sendable {
    /// ReviewDesk's review prompt, answered as JSON in one call.
    case generic
    /// Claude Code's `/code-review`, then a tool-less pass that turns its report into findings.
    case codeReview
    /// Codex's built-in review (`codex exec review`), then the same tool-less pass.
    case codexReview
    /// A review prompt the user saved (`ReviewTemplate`), for Ollama.
    case saved(UUID)

    /// The provider's own commands, best first; saved prompts are listed separately.
    public static func builtIn(for engine: AIEngine) -> [ReviewCommand] {
        switch engine {
        case .claudeCode, .claudeSession: [.codeReview, .generic]
        case .codex: [.codexReview, .generic]
        case .ollama: [.generic]
        }
    }

    /// Claude Code keeps `/code-review`; Codex and Ollama keep ReviewDesk's prompt until the user picks another.
    public static func fallback(for engine: AIEngine) -> ReviewCommand {
        engine.tool == "claude" ? .codeReview : .generic
    }

    /// The command `stored` names for `engine`. One that isn't `engine`'s (another provider's, a deleted saved prompt,
    /// an unknown value) falls back to the provider's default, so a stale setting never runs the wrong thing.
    public static func resolve(_ stored: String?, for engine: AIEngine, saved: [ReviewTemplate]) -> ReviewCommand {
        let builtIn = builtIn(for: engine)
        if let command = builtIn.first(where: { $0.stored == stored }) { return command }
        if case .ollama = engine, let id = stored.flatMap(UUID.init(uuidString:)), saved.contains(where: { $0.id == id }) {
            return .saved(id)
        }
        return fallback(for: engine)
    }

    /// How settings keep it.
    public var stored: String {
        switch self {
        case .generic: "generic"
        case .codeReview: "code-review"
        case .codexReview: "codex-review"
        case .saved(let id): id.uuidString
        }
    }

    /// Its name in pickers and on a run's card.
    public func label(saved: [ReviewTemplate]) -> String {
        switch self {
        case .generic: "ReviewDesk prompt"
        case .codeReview: "/code-review"
        case .codexReview: "Codex review"
        case .saved(let id): saved.first { $0.id == id }?.name ?? "Saved prompt"
        }
    }

    /// Codex and Ollama, and Claude Code on the generic prompt, show their context in *Prepare Context* first.
    public var preparesContext: Bool { self != .codeReview }
}

/// A review prompt the user saved, for providers without a review command of their own (Ollama). It's a prompt
/// template, never a command: nothing in it is executed, and the provider still runs without tools. Placeholders
/// (`{diff}`, `{title}`…) are filled from the prepared context; anything else in braces is sent as typed.
public struct ReviewTemplate: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var template: String

    public init(name: String, template: String = ReviewTemplate.starter) {
        (self.name, self.template) = (name, template)
    }

    /// The placeholders and what each one is filled with.
    public static let placeholders: [(name: String, help: String)] = [
        ("title", "the pull request's title"),
        ("description", "its description"),
        ("diff", "the diffs of the files kept in Prepare Context"),
        ("files", "those files in full at the head commit"),
        ("rules", "the repository's rules (AGENTS.md, CONTRIBUTING.md…)"),
        ("context", "the project's AI context"),
        ("conversation", "the pull request's conversation"),
    ]

    /// What *Add…* starts from: every placeholder, in a sensible order.
    public static let starter = """
    Review this pull request. Report real problems (bugs, security, data loss, missing error handling), not style.

    # {title}

    {description}

    {rules}
    {context}
    ## Conversation

    {conversation}

    {diff}
    {files}
    """

    /// The template with its placeholders filled from `context`, in one pass, so text the context brings in (a diff
    /// mentioning `{title}`, say) is never filled again. Unknown placeholders stay as typed.
    public func filled(_ context: ReviewContext) -> String {
        var output = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            output += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let value = Self.value(String(after[..<close]), context) {
                output += value
                rest = after[after.index(after: close)...]
            } else {
                output += "{"
                rest = after
            }
        }
        return output + rest
    }

    /// The prompt sent: the filled template, then the result format, which a template can't change, so the answer
    /// still parses into findings, key areas and risk answers.
    public func prompt(_ context: ReviewContext) -> String {
        filled(context) + "\n\n" + AIContext.resultFormat
    }

    private static func value(_ name: String, _ context: ReviewContext) -> String? {
        switch name {
        case "title": context.title
        case "description": context.body
        case "diff": AIContext.diffs(context.files)
        case "files":
            context.files.filter(\.included).compactMap { file in
                file.content.map { "\n## Full file at head: \(file.path)\n" + AIContext.fenced($0, info: "") + "\n" }
            }.joined()
        case "rules": RepoRules.section(context.rules)
        case "context": ProjectContext.section(context.extra)
        case "conversation": context.conversation
        default: nil
        }
    }
}
