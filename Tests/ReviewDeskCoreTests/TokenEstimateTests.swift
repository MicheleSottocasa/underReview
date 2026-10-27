import Foundation
import Testing
@testable import ReviewDeskCore

@Test func codeReviewDefaultsCoverTheMeasuredRuns() {
    // Measured on a 469-token diff: 31,898 tokens at low effort and 109,250 at high.
    let low = TokenEstimator.codeReview(input: 469, effort: "low")
    let high = TokenEstimator.codeReview(input: 469, effort: "high")
    #expect(low.low <= 31_898 && 31_898 <= low.high)
    #expect(high.low <= 109_250 && 109_250 <= high.high)
    #expect(!low.calibrated)
    // Bigger pull requests and higher efforts cost more.
    #expect(TokenEstimator.codeReview(input: 40_000, effort: "high").low > high.high)
    #expect(TokenEstimator.codeReview(input: 469, effort: "max").low > low.high)
}

@Test func pastRunsCalibrateTheCodeReviewRange() {
    let center = TokenEstimator.codeReviewCenter(input: 1_000, effort: "high")
    // Three past runs at 1.0×, 1.2× and 1.5× the default: the range becomes 1.0×–1.5× of it.
    let history = [1.0, 1.2, 1.5].map { TokenEstimator.Sample(effort: "high", input: 1_000, actual: Int(center * $0)) }
    let estimate = TokenEstimator.codeReview(input: 1_000, effort: "high", history: history)
    #expect(estimate.calibrated)
    #expect(abs(estimate.low - Int(center)) <= 1 && abs(estimate.high - Int(center * 1.5)) <= 1)
    // Runs at another effort, or too few runs, don't calibrate.
    #expect(!TokenEstimator.codeReview(input: 1_000, effort: "low", history: history).calibrated)
    #expect(!TokenEstimator.codeReview(input: 1_000, effort: "high", history: Array(history.prefix(2))).calibrated)
}

@Test func promptEstimatesAddTheCLIOverheadAndAnAnswer() {
    let text = String(repeating: "x", count: 4_000) // ~1k tokens
    let claude = TokenEstimator.prompt(text, engine: .claudeCode, answer: .chat)
    let codex = TokenEstimator.prompt(text, engine: .codex, answer: .chat)
    #expect(claude.low > 1_000 && claude.high < 6_000)
    #expect(codex.low > claude.low) // Codex's own prompt is bigger
    #expect(TokenEstimator.prompt(text, engine: .claudeCode, answer: .review).high > claude.high)
}

@Test func estimatesAddUpAndRead() {
    let total = TokenEstimate(low: 30_000, high: 50_000) + TokenEstimate(low: 2_000, high: 60_000)
    #expect(total == TokenEstimate(low: 32_000, high: 110_000))
    #expect(total.label == "~32k–110k tokens")
    #expect(TokenEstimate.sum([TokenEstimate(low: 1, high: 2), TokenEstimate(low: 3, high: 4)]) == TokenEstimate(low: 4, high: 6))
    #expect(TokenEstimate.sum([]) == nil)
    #expect(TokenEstimate(low: 2_610, high: 2_640).label == "~2.6k tokens")
}

@Test func codeReviewRunsBecomeSamples() {
    var run = AIRun(prID: "PR_1", engine: .claudeCode, headRefOid: "h", result: ReviewResult(summary: "", findings: []))
    #expect(run.sample == nil)
    run.options = AIOptions(effort: "low")
    run.estimatedTokens = 469
    run.usage = TokenUsage(input: 8, output: 1_100, cacheRead: 30_790)
    #expect(run.sample == TokenEstimator.Sample(effort: "low", input: 469, actual: 31_898))
}

@Test func codexAndOllamaRunsDontCalibrateCodeReview() {
    var run = AIRun(prID: "PR_1", engine: .codex, headRefOid: "h", result: ReviewResult(summary: "", findings: []))
    run.options = AIOptions(effort: "high")
    run.estimatedTokens = 469
    run.usage = TokenUsage(input: 8, output: 1_100, cacheRead: 30_790)
    #expect(run.sample == nil)
}
