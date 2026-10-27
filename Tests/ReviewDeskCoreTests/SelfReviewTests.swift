import Foundation
import Testing
@testable import ReviewDeskCore

private func finding(_ title: String, _ severity: String, path: String? = "a.py", line: Int? = 10) -> Finding {
    Finding(severity: severity, title: title, rationale: "", path: path, line: line, comment: title)
}

@Test func selfReviewInstructionsKeepThePromptAndAddTheFocus() {
    let tests = SelfReview.focuses.first { $0.id == "tests" }!
    let text = SelfReview.instructions("Review this PR.", focus: tests)
    #expect(text.hasPrefix("Review this PR.\n\n"))
    #expect(text.contains("Yours is tests: changed behavior with no test"))
    #expect(Set(SelfReview.focuses.map(\.id)).count == SelfReview.focuses.count)
}

@Test func selfReviewMergesTheAgentsAndDropsDuplicateFindings() {
    let (correctness, tests, security) = (SelfReview.focuses[0], SelfReview.focuses[1], SelfReview.focuses[2])
    let parts: [(focus: ReviewFocus, result: ReviewResult)] = [
        (correctness, ReviewResult(summary: "One bug.", findings: [finding("Missing nil check on user", "medium"), finding("General naming", "low", path: nil, line: nil)],
                                   keyAreas: [KeyArea(path: "a.py", startLine: 8, endLine: 12, reason: "core")],
                                   risks: [RiskAssessment(question: "data", level: "low", answer: "a")])),
        (security, ReviewResult(summary: "An auth hole.", findings: [
            finding("Nil check missing on user", "high", line: 11),     // the same issue, more severe: it wins
            finding("Missing nil check on user", "high", line: 30),     // too far away: another issue
            finding("Token logged in plain text", "critical", line: 10), // same line, other words: another issue
        ], keyAreas: [KeyArea(path: "a.py", startLine: 8, endLine: 12, reason: "auth")],
           risks: [RiskAssessment(question: "data", level: "high", answer: "b"), RiskAssessment(question: "scale", level: "none", answer: "c")])),
    ]
    let merged = SelfReview.merge(parts, missing: [tests])
    #expect(merged.summary == "**Correctness:** One bug.\n\n**Security:** An auth hole.\n\n_Not reviewed: Tests._")
    #expect(merged.findings.map(\.title) == ["Nil check missing on user", "General naming", "Missing nil check on user", "Token logged in plain text"])
    #expect(merged.findings[0].severity == "high" && merged.findings[0].line == 11)
    #expect(merged.keyAreas.count == 1 && merged.keyAreas[0].reason == "core")
    #expect(merged.risks.map(\.level) == ["high", "none"])
}

@Test func selfReviewKeepsTheLowestScore() {
    let (correctness, tests, security) = (SelfReview.focuses[0], SelfReview.focuses[1], SelfReview.focuses[2])
    let merged = SelfReview.merge([(correctness, ReviewResult(summary: "", findings: [], score: 8.5)),
                                   (tests, ReviewResult(summary: "", findings: [])),
                                   (security, ReviewResult(summary: "", findings: [], score: 3.2))])
    #expect(merged.score == 3.2)
    #expect(SelfReview.merge([(tests, ReviewResult(summary: "", findings: []))]).score == nil)
}

@Test func selfReviewRunsAreNotCalibrationSamples() {
    var run = AIRun(prID: "PR_1", engine: .claudeCode, headRefOid: "h", result: ReviewResult(summary: "", findings: []))
    (run.options, run.estimatedTokens, run.usage) = (AIOptions(), 1_000, TokenUsage(input: 10, output: 5))
    #expect(run.sample != nil)
    run.agents = ["Correctness", "Tests"]
    #expect(run.sample == nil)
}
