import Foundation

/// One concern of a self-review, reviewed by its own agent.
public struct ReviewFocus: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// What the agent looks for, added to the review instructions.
    public var instructions: String

    public init(id: String, title: String, instructions: String) {
        (self.id, self.title, self.instructions) = (id, title, instructions)
    }
}

/// The author's own review before asking others: several agents read the same context in parallel, each on one
/// concern, and their findings are merged into one review.
public enum SelfReview {
    public static let focuses = [
        ReviewFocus(id: "correctness", title: "Correctness",
                    instructions: "bugs: wrong logic, missed edge cases, error handling, concurrency, and callers the change breaks."),
        ReviewFocus(id: "tests", title: "Tests",
                    instructions: "tests: changed behavior with no test, tests that don't check what they claim, and fixes without a regression test."),
        ReviewFocus(id: "security", title: "Security",
                    instructions: "security and data: injection, secrets, authorization, unsafe input, data loss and risky migrations."),
        ReviewFocus(id: "rules", title: "Repository rules",
                    instructions: "the repository's rules included below (AGENTS.md, CONTRIBUTING.md…) and the code's own conventions; skip what a linter or formatter enforces."),
    ]

    /// One agent's instructions: the editable review prompt, then its focus.
    public static func instructions(_ instructions: String, focus: ReviewFocus) -> String {
        instructions + "\n\nThis is the author's own review before asking others for one. Several reviewers work on it in "
            + "parallel, one concern each. Yours is \(focus.instructions) Report only findings about that; the others cover the rest."
    }

    /// One review from the agents' results, in focus order: a summary paragraph per focus (and the ones that didn't
    /// finish), findings without duplicates, key areas once each and the highest level per risk question. Findings
    /// are duplicates when they're on the same file (or both general), at most 2 lines apart, with mostly the same
    /// title words; the more severe one stays.
    public static func merge(_ parts: [(focus: ReviewFocus, result: ReviewResult)], missing: [ReviewFocus] = []) -> ReviewResult {
        var summary = parts.map { "**\($0.focus.title):** \($0.result.summary)" }
        if !missing.isEmpty { summary.append("_Not reviewed: \(missing.map(\.title).joined(separator: ", "))._") }
        var findings: [Finding] = []
        for finding in parts.flatMap(\.result.findings) {
            if let index = findings.firstIndex(where: { isDuplicate($0, finding) }) {
                if rank(finding.severity) > rank(findings[index].severity) { findings[index] = finding }
            } else {
                findings.append(finding)
            }
        }
        var areas: [KeyArea] = []
        for area in parts.flatMap(\.result.keyAreas)
            where !areas.contains(where: { ($0.path, $0.startLine, $0.endLine, $0.side) == (area.path, area.startLine, area.endLine, area.side) }) {
            areas.append(area)
        }
        var risks: [RiskAssessment] = []
        for risk in parts.flatMap(\.result.risks) {
            if let index = risks.firstIndex(where: { $0.question == risk.question }) {
                if risk.rank > risks[index].rank { risks[index] = risk }
            } else {
                risks.append(risk)
            }
        }
        return ReviewResult(summary: summary.joined(separator: "\n\n"), findings: findings, keyAreas: areas, risks: risks)
    }

    static func isDuplicate(_ a: Finding, _ b: Finding) -> Bool {
        guard a.path == b.path else { return false }
        switch (a.line, b.line) {
        case (nil, nil): break
        case let (x?, y?) where abs(x - y) <= 2: break
        default: return false
        }
        let (x, y) = (words(a.title), words(b.title))
        guard !x.isEmpty, !y.isEmpty else { return a.title == b.title }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.5
    }

    /// Lowercased words of three letters or more: "Missing nil check" → missing, nil, check.
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }

    /// low 0 … critical 3; unknown severities rank lowest.
    static func rank(_ severity: String) -> Int {
        ["low", "medium", "high", "critical"].firstIndex(of: severity) ?? -1
    }
}
