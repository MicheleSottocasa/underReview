import Foundation

public struct Finding: Codable, Hashable, Sendable {
    public var severity: String
    public var title: String
    public var rationale: String
    public var path: String?
    public var line: Int?
    public var comment: String

    public init(severity: String, title: String, rationale: String, path: String?, line: Int?, comment: String) {
        (self.severity, self.title, self.rationale, self.path, self.line, self.comment) = (severity, title, rationale, path, line, comment)
    }

    public var anchor: Anchor? {
        guard let path, let line else { return nil }
        return Anchor(path: path, line: line)
    }
}

/// A part of the change the reviewer should read personally before submitting.
public struct KeyArea: Codable, Hashable, Sendable {
    public var path: String
    /// Line range on the new side; nil for the whole file.
    public var startLine: Int?
    public var endLine: Int?
    public var reason: String
    /// Which risk question it answers (a `RiskQuestion` raw value, or "other"). Nil in reviews saved before risk tags.
    public var risk: String?

    public init(path: String, startLine: Int? = nil, endLine: Int? = nil, reason: String, risk: String? = nil) {
        (self.path, self.startLine, self.endLine, self.reason, self.risk) = (path, startLine, endLine, reason, risk)
    }

    public var question: RiskQuestion? { risk.flatMap(RiskQuestion.init) }

    public func contains(line: Int) -> Bool {
        guard let startLine else { return false }
        return (startLine...max(startLine, endLine ?? startLine)).contains(line)
    }
}

/// The AI's answer to one risk question for this PR.
public struct RiskAssessment: Codable, Hashable, Sendable {
    public static let levels = ["none", "low", "medium", "high"]

    /// A `RiskQuestion` raw value.
    public var question: String
    /// none (the PR doesn't touch it), low, medium or high.
    public var level: String
    public var answer: String

    public init(question: String, level: String, answer: String) {
        (self.question, self.level, self.answer) = (question, level, answer)
    }

    public var riskQuestion: RiskQuestion? { RiskQuestion(rawValue: question) }
    /// 0 for none up to 3 for high; unknown levels sort as none.
    public var rank: Int { Self.levels.firstIndex(of: level) ?? 0 }
}

public struct ReviewResult: Codable, Hashable, Sendable {
    public var summary: String
    public var findings: [Finding]
    public var keyAreas: [KeyArea]
    public var risks: [RiskAssessment]

    public init(summary: String, findings: [Finding], keyAreas: [KeyArea] = [], risks: [RiskAssessment] = []) {
        self.summary = summary
        self.findings = findings
        self.keyAreas = keyAreas
        self.risks = risks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        findings = try container.decode([Finding].self, forKey: .findings)
        // Reviews saved before key areas or risk answers existed have none.
        keyAreas = try container.decodeIfPresent([KeyArea].self, forKey: .keyAreas) ?? []
        risks = try container.decodeIfPresent([RiskAssessment].self, forKey: .risks) ?? []
    }

    /// The answer to one question, if the review gave one.
    public func risk(_ question: RiskQuestion) -> RiskAssessment? {
        risks.first { $0.question == question.rawValue }
    }
}

public struct ContextFile: Hashable, Identifiable, Sendable {
    public var path: String
    public var patch: String?
    /// Full file at the head commit; nil for deleted files.
    public var content: String?
    public var included: Bool
    /// Why the file can't be sent at all (shown to the user, never silently dropped).
    public var excludedReason: String?

    public var id: String { path }
    public var tokens: Int { AIContext.estimateTokens((patch ?? "") + (content ?? "")) }
}

public struct ReviewContext: Sendable {
    public var title: String
    public var body: String
    public var files: [ContextFile]
    public var budget: Int
    /// The repository's rule files (AGENTS.md, CONTRIBUTING.md…), shown and sent like files.
    public var rules: [ContextFile] = []

    public init(title: String, body: String, files: [ContextFile], budget: Int, rules: [ContextFile] = []) {
        (self.title, self.body, self.files, self.budget, self.rules) = (title, body, files, budget, rules)
    }

    public var tokens: Int { (files + rules).filter(\.included).reduce(AIContext.estimateTokens(title + body)) { $0 + $1.tokens } }

    /// Keeps files in order while they fit the budget; the rest are left out and named in the prompt.
    /// Rules always stay: they're short, and reviewing against them is the point.
    public func fittingBudget() -> ReviewContext {
        var context = self
        var used = rules.filter(\.included).reduce(AIContext.estimateTokens(title + body)) { $0 + $1.tokens }
        for index in context.files.indices where context.files[index].included {
            if used + context.files[index].tokens > budget { context.files[index].included = false } else { used += context.files[index].tokens }
        }
        return context
    }
    /// Over budget means the user must deselect files: we never truncate silently.
    public var fitsBudget: Bool { tokens <= budget }
}

/// One message in the Explain chat.
public struct ChatMessage: Hashable, Sendable {
    public enum Role: Hashable, Sendable { case reviewer, assistant }

    public var role: Role
    public var text: String

    public init(_ role: Role, _ text: String) {
        (self.role, self.text) = (role, text)
    }
}

public enum AIContext {
    /// Strict-mode friendly (Codex requires every property listed and no extras).
    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["summary","findings","keyAreas","risks"],"properties":{
      "summary":{"type":"string"},
      "risks":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["question","level","answer"],"properties":{
          "question":{"type":"string","enum":["data","access","scale","failure","explain"]},
          "level":{"type":"string","enum":["none","low","medium","high"]},
          "answer":{"type":"string"}}}},
      "keyAreas":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["path","startLine","endLine","reason","risk"],"properties":{
          "path":{"type":"string"},
          "startLine":{"type":["integer","null"]},
          "endLine":{"type":["integer","null"]},
          "reason":{"type":"string"},
          "risk":{"type":"string","enum":["data","access","scale","failure","explain","other"]}}}},
      "findings":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["severity","title","rationale","path","line","comment"],"properties":{
          "severity":{"type":"string","enum":["critical","high","medium","low"]},
          "title":{"type":"string"},
          "rationale":{"type":"string"},
          "path":{"type":["string","null"]},
          "line":{"type":["integer","null"]},
          "comment":{"type":"string"}}}}}}
    """

    // ponytail: chars/4 token estimate; the CLIs expose no tokenizer. Swap in a real count if budgets bite.
    public static func estimateTokens(_ text: String) -> Int { text.utf8.count / 4 + 1 }

    /// Diff plus full content of each changed file at head. Files GitHub gave no patch for are listed as excluded.
    public static func build(pr: PullRequest, body: String, files: [FileChange], contents: [String: String], budget: Int,
                             rules: [String: String] = [:]) -> ReviewContext {
        let contextFiles = files.map { file in
            let reason: String? = file.patch == nil ? "GitHub omitted the diff (binary or too large)" : nil
            return ContextFile(path: file.filename, patch: file.patch, content: contents[file.filename], included: reason == nil, excludedReason: reason)
        }
        return ReviewContext(title: pr.title, body: body, files: contextFiles, budget: budget,
                             rules: RepoRules.contextFiles(rules, changed: files.map(\.filename)))
    }

    /// How key areas are asked for, shared by every review prompt.
    static let keyAreasInstructions = """
    In `keyAreas`, list the files and sections the reviewer must read personally before submitting the review
    (usually 3 to 8). Review risk, not lines: tag each with `risk`, in this order of priority: `data` (migrations,
    model changes, writes, transactions, defaults), `access` (who may do this: permission checks, queries scoped to
    the user or organisation), `scale` (behaviour at 100x the data: N+1 queries, missing indexes, whole tables loaded
    into memory), `failure` (timeouts, retries, tasks running twice, double submits), `explain` (non-trivial design
    the author should explain) or `other`. If the PR description has Risk notes, make every item the author is unsure
    about a key area. Never flag formatting, naming or style. Give line ranges on the NEW side of the diff; use null
    lines for a whole file. `reason` says in one sentence what to check there.
    In `risks`, answer each of these questions about this PR exactly once, in this order: `data` (what changes about
    the data?), `access` (who is allowed to do this?), `scale` (what happens at 100x the data?), `failure` (what
    happens when it fails?), `explain` (can the author explain it: is the design non-obvious enough to ask?). `level`
    is none when the PR doesn't touch it, otherwise low, medium or high by how likely and how costly a mistake would
    be. `answer` gives the evidence in one to three sentences, naming the files or functions involved.
    """

    /// Editable in Settings. The JSON schema is always appended, so a custom prompt can't break parsing.
    public static let defaultReviewInstructions = """
    You are reviewing a GitHub pull request. Use only the material below; do not run tools or commands.
    Report real problems (bugs, security, data loss, concurrency, missing error handling, unclear code) as findings.
    For inline findings set `path` and `line` to a line number on the NEW side of the diff that appears in a hunk.
    Use null path/line for general remarks. `comment` is the text to post on GitHub, in Markdown.
    Check the change against the repository rules included below (AGENTS.md, CLAUDE.md, CONTRIBUTING.md and the
    like): report each violation as a finding that quotes the rule, but skip rules a linter or formatter enforces.
    \(keyAreasInstructions)
    """

    /// Appended to Claude Code's system prompt when it runs `/code-review` for the app. Editable in Settings.
    public static let defaultCodeReviewInstructions = """
    You are running inside ReviewDesk, a pull request review app. Never post anything to GitHub (no comments,
    reviews or reactions) and never modify files. Run gh commands on their own, without pipes or redirections.
    """

    /// Turns the `/code-review` report into the app's findings and key areas. Editable in Settings;
    /// the JSON schema, the report and the diff are always appended.
    public static let defaultStructureInstructions = """
    Below is a code review of a GitHub pull request, written by Claude Code's /code-review, followed by the PR's diff.
    Turn the review into findings: one per issue it reports, never adding issues it doesn't contain, except that you
    check the diff against the repository rules (if included) and add a finding for each clear violation the review
    didn't report, quoting the rule; skip rules a linter or formatter enforces. For each finding, keep
    the review's substance in `comment` (the text to post on GitHub, in Markdown), pick a severity (critical, high,
    medium or low), write a short title and the rationale, and set `path` and `line` to a line on the NEW side of the
    diff that appears in a hunk, or null for general remarks. `summary` is the review's verdict in two or three
    sentences. If the review found nothing, return no findings and say so in the summary.
    \(keyAreasInstructions)
    """

    public static func structurePrompt(report: String, context: ReviewContext, instructions: String = defaultStructureInstructions) -> String {
        var text = """
        \(instructions)
        Reply only with JSON matching this schema:
        \(schema)

        # \(context.title)

        \(context.body)

        ## Review from /code-review

        \(report)

        """
        // /code-review's helper agent never sees our instructions, so the rules are checked here, against the diff.
        text += RepoRules.section(context.rules)
        for file in context.files where file.included {
            text += "\n## Diff: \(file.path)\n```diff\n\(file.patch ?? "")\n```\n"
        }
        let skipped = context.files.filter { !$0.included }.map(\.path)
        if !skipped.isEmpty {
            text += "\nThe diffs of these changed files were not provided: \(skipped.joined(separator: ", ")).\n"
        }
        return text
    }

    public static func prompt(_ context: ReviewContext, instructions: String = defaultReviewInstructions) -> String {
        var text = """
        \(instructions)
        Reply only with JSON matching this schema:
        \(schema)

        # \(context.title)

        \(context.body)

        """
        text += RepoRules.section(context.rules)
        for file in context.files where file.included {
            text += "\n## Diff: \(file.path)\n```diff\n\(file.patch ?? "")\n```\n"
            if let content = file.content {
                text += "\n## Full file at head: \(file.path)\n```\n\(content)\n```\n"
            }
        }
        let skipped = context.files.filter { !$0.included }.map(\.path)
        if !skipped.isEmpty {
            text += "\nThese changed files were not provided: \(skipped.joined(separator: ", ")).\n"
        }
        return text
    }

    /// Asks for a plain-language explanation of one comment, with the code and conversation around it.
    /// Editable in Settings.
    public static let defaultExplainInstructions = """
    You are helping someone review a GitHub pull request. Explain the comment marked **[EXPLAIN THIS]** below
    in plain language: what the commenter means, why it matters, and what change (if any) they are asking for.
    If the comment looks wrong or unclear, say so. Use only the material below; do not run tools or commands.
    Reply briefly, in Markdown.
    """

    public static func explainPrompt(title: String, body: String, path: String?, line: Int?, patch: String?,
                                     conversation: [Comment], comment: Comment,
                                     instructions: String = defaultExplainInstructions) -> String {
        var text = """
        \(instructions)

        # \(title)

        \(body)

        """
        if let path {
            text += "\n## Code: \(path)\(line.map { ", line \($0)" } ?? "")\n"
            text += patch.map { "```diff\n\($0)\n```\n" } ?? "(diff not available)\n"
        }
        text += "\n## Conversation\n"
        for entry in conversation {
            text += "\n**\(entry.author)**\(entry.id == comment.id ? " **[EXPLAIN THIS]**" : ""):\n\(entry.body)\n"
        }
        return text
    }

    /// A follow-up in the Explain chat. Each call stands alone (it works the same with every engine), so it
    /// resends the original explain prompt, with its PR description, conversation and diff, plus the chat so far.
    public static func followUpPrompt(explainPrompt: String, chat: [ChatMessage], question: String) -> String {
        var text = explainPrompt + (chat.isEmpty ? "" : "\n## Chat about this comment so far\n")
        for message in chat {
            text += "\n**\(message.role == .reviewer ? "Reviewer" : "You")**:\n\(message.text)\n"
        }
        text += """

        ## The reviewer's new question

        \(question)

        Answer this question, briefly, in Markdown. Keep using only the material above; if it doesn't hold the answer, say so.
        """
        return text
    }

    /// Where an accepted finding goes. Anything that points at a changed file becomes an inline comment: on its line
    /// when GitHub accepts a comment there, otherwise on the nearest line it does in that file, with the original line
    /// named in the text. Only general remarks, and files without a diff, go to the review summary.
    public enum Placement: Equatable, Sendable {
        case inline(Anchor, body: String)
        case summary(String)
    }

    public static func placement(_ finding: Finding, files: [FileChange]) -> Placement {
        guard let path = finding.path, let patch = files.first(where: { $0.filename == path })?.patch else {
            let reference = finding.path.map { "`\($0)\(finding.line.map { ":\($0)" } ?? "")`: " } ?? ""
            return .summary(reference + finding.comment)
        }
        let anchors = Diff.anchors(path: path, patch: patch)
        if let line = finding.line, anchors.contains(Anchor(path: path, line: line)) {
            return .inline(Anchor(path: path, line: line), body: finding.comment)
        }
        // Prefer the new side (what the PR adds or keeps), then the closest line, then the earlier one on a tie.
        let target = finding.line ?? 0
        guard let nearest = anchors.min(by: { a, b in
            (a.side == .left ? 1 : 0, abs(a.line - target), a.line) < (b.side == .left ? 1 : 0, abs(b.line - target), b.line)
        }) else { return .summary("`\(path)`: " + finding.comment) }
        let note = finding.line.map { "**Line \($0):** " } ?? "**This file:** "
        return .inline(nearest, body: note + finding.comment)
    }

    /// Splits findings into ones GitHub will accept inline and general suggestions.
    public static func validate(_ result: ReviewResult, files: [FileChange]) -> (inline: [Finding], general: [Finding]) {
        let anchors = files.reduce(into: Set<Anchor>()) { set, file in
            if let patch = file.patch { set.formUnion(Diff.anchors(path: file.filename, patch: patch)) }
        }
        var inline: [Finding] = [], general: [Finding] = []
        for finding in result.findings {
            if let anchor = finding.anchor, anchors.contains(anchor) { inline.append(finding) } else { general.append(finding) }
        }
        return (inline, general)
    }
}
