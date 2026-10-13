import Foundation

/// The risk-first review questions, in the order to ask them: data first, because "if the data layer is wrong,
/// nothing else in the PR matters". Style, naming and taste are left to linters.
public enum RiskQuestion: String, CaseIterable, Codable, Hashable, Sendable {
    case data, access, scale, failure, explain

    public var title: String {
        switch self {
        case .data: "What changes about the data?"
        case .access: "Who is allowed to do this?"
        case .scale: "What happens at 100× the data?"
        case .failure: "What happens when it fails?"
        case .explain: "Can the author explain it?"
        }
    }

    public var label: String {
        switch self {
        case .data: "Data"
        case .access: "Access"
        case .scale: "Scale"
        case .failure: "Failure"
        case .explain: "Explain"
        }
    }

    public var guidance: String {
        switch self {
        case .data: "Migrations, model changes and writes: locking migrations, renamed or removed fields old code still reads, writes without a transaction, defaults backfilling millions of rows."
        case .access: "For every new endpoint or view: can a user reach data that isn't theirs? Queries must be scoped to the current user or organisation, not just filtered by an id from the request."
        case .scale: "Read every database touch slowly: N+1 queries, missing select/prefetch, unindexed filters, whole tables loaded into memory."
        case .failure: "External API timeouts, background tasks running twice, double clicks. \"It probably won't happen\" means it will."
        case .explain: "For non-trivial changes, ask for the approach in two or three sentences: does the author own the design?"
        }
    }

    /// Words that tie a line of the author's Risk notes to this question.
    var keywords: [String] {
        switch self {
        case .data: ["data", "migration", "schema", "database", "model"]
        case .access: ["permission", "access", "auth", "security", "who"]
        case .scale: ["performance", "scale", "query", "queries", "load", "index"]
        case .failure: ["fail", "error", "retry", "timeout", "rollback"]
        case .explain: ["approach", "design", "explain"]
        }
    }
}

/// The "Risk notes" section of a PR description, split by question.
public struct RiskNotes: Hashable, Sendable {
    /// The whole section, as Markdown.
    public var markdown: String
    public var byQuestion: [RiskQuestion: [String]]
    /// "Anything I'm unsure about": where the author points the reviewer.
    public var unsure: [String]
}

public enum Risk {
    /// The PR template section authors fill in before review.
    public static let template = """
    ## Risk notes
    - **Data changes:**
    - **Permission impact:**
    - **Performance concerns:**
    - **Failure handling:**
    - **Anything I'm unsure about:**
    """

    /// Finds a "Risk notes" heading (or bold line) and reads it until the next heading of the same or higher level.
    public static func notes(in body: String) -> RiskNotes? {
        let lines = body.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { isRiskHeading($0) }) else { return nil }
        let level = headingLevel(lines[start]) ?? 7
        var section: [String] = []
        for line in lines[(start + 1)...] {
            if let next = headingLevel(line), next <= level { break }
            section.append(line)
        }
        var byQuestion: [RiskQuestion: [String]] = [:]
        var unsure: [String] = []
        var current: RiskLabel?
        for raw in section {
            var line = raw.trimmingCharacters(in: .whitespaces)
            for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) { line = String(line.dropFirst(prefix.count)) }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
            guard !line.isEmpty else { continue }
            // "**Label:** text", "Label: text" or a bare label/subheading that applies to the lines after it.
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces) }
            if let label = RiskLabel(parts[0]) {
                current = label
                guard parts.count == 2, !parts[1].isEmpty else { continue }
                line = parts[1]
            }
            switch current {
            case .unsure: unsure.append(line)
            case .question(let question): byQuestion[question, default: []].append(line)
            case nil: continue
            }
        }
        return RiskNotes(markdown: section.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                         byQuestion: byQuestion, unsure: unsure)
    }

    // ponytail: path heuristic for "this PR touches the data layer"; it only prompts a closer look.
    /// Changed files that look like data-layer changes: migrations, schemas, SQL and model definitions.
    public static func dataFiles(_ paths: [String]) -> [String] {
        paths.filter { path in
            let lower = path.lowercased(), name = (lower as NSString).lastPathComponent
            return lower.contains("migration") || lower.contains("/migrate/") || lower.contains("alembic/versions")
                || name.hasSuffix(".sql") || name == "models.py" || lower.contains("/models/")
                || name == "schema.prisma" || name == "schema.rb" || name.hasSuffix(".graphql")
        }
    }

    private static func isRiskHeading(_ line: String) -> Bool {
        let text = line.lowercased()
        return text.contains("risk notes") && (headingLevel(line) != nil || text.trimmingCharacters(in: .whitespaces).hasPrefix("**"))
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        return (1...6).contains(hashes) && line.dropFirst(hashes).first == " " ? hashes : nil
    }
}

private enum RiskLabel {
    case unsure
    case question(RiskQuestion)

    /// Short label-like text only, so a sentence that mentions "data" isn't mistaken for a label.
    init?(_ text: String) {
        let label = text.lowercased()
        guard label.count <= 40 else { return nil }
        if ["unsure", "not sure", "uncertain", "doubt"].contains(where: label.contains) { self = .unsure; return }
        guard let question = RiskQuestion.allCases.first(where: { $0.keywords.contains(where: label.contains) }) else { return nil }
        self = .question(question)
    }
}
