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

public struct ReviewResult: Codable, Hashable, Sendable {
    public var summary: String
    public var findings: [Finding]
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

    public var tokens: Int { files.filter(\.included).reduce(AIContext.estimateTokens(title + body)) { $0 + $1.tokens } }
    /// Over budget means the user must deselect files: we never truncate silently.
    public var fitsBudget: Bool { tokens <= budget }
}

public enum AIContext {
    /// Strict-mode friendly (Codex requires every property listed and no extras).
    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["summary","findings"],"properties":{
      "summary":{"type":"string"},
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
    public static func build(pr: PullRequest, body: String, files: [FileChange], contents: [String: String], budget: Int) -> ReviewContext {
        let contextFiles = files.map { file in
            let reason: String? = file.patch == nil ? "GitHub omitted the diff (binary or too large)" : nil
            return ContextFile(path: file.filename, patch: file.patch, content: contents[file.filename], included: reason == nil, excludedReason: reason)
        }
        return ReviewContext(title: pr.title, body: body, files: contextFiles, budget: budget)
    }

    public static func prompt(_ context: ReviewContext) -> String {
        var text = """
        You are reviewing a GitHub pull request. Use only the material below; do not run tools or commands.
        Report real problems (bugs, security, data loss, concurrency, missing error handling, unclear code) as findings.
        For inline findings set `path` and `line` to a line number on the NEW side of the diff that appears in a hunk.
        Use null path/line for general remarks. `comment` is the text to post on GitHub, in Markdown.
        Reply only with JSON matching this schema:
        \(schema)

        # \(context.title)

        \(context.body)

        """
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
