import Foundation

/// How many tokens a run is likely to use: a range, since the answer's length (and for `/code-review`, how much the
/// agent reads) is only known afterwards.
public struct TokenEstimate: Equatable, Sendable {
    public var low: Int
    public var high: Int
    /// The `/code-review` range was fitted to this machine's past runs at the same effort, not the built-in defaults.
    public var calibrated = false

    public init(low: Int, high: Int, calibrated: Bool = false) {
        (self.low, self.high, self.calibrated) = (min(low, high), max(low, high), calibrated)
    }

    public static func + (a: TokenEstimate, b: TokenEstimate) -> TokenEstimate {
        TokenEstimate(low: a.low + b.low, high: a.high + b.high, calibrated: a.calibrated && b.calibrated)
    }

    /// The total of several runs; nil for none.
    public static func sum(_ estimates: [TokenEstimate]) -> TokenEstimate? {
        guard let first = estimates.first else { return nil }
        return estimates.dropFirst().reduce(first, +)
    }

    /// "~32k tokens", or "~30k–110k tokens" when the range is wide.
    public var label: String {
        let (from, to) = (TokenUsage.formatted(low), TokenUsage.formatted(high))
        return from == to ? "~\(from) tokens" : "~\(from)–\(to) tokens"
    }
}

/// Estimates before running. The input the app builds is counted (characters ÷ 4); what the CLI adds on top, and the
/// answer, come from measured runs: tool-less calls, and `/code-review` on a small pull request at each effort.
public enum TokenEstimator {
    /// A past `/code-review` to calibrate against: the input estimate it ran with and what it really used.
    public struct Sample: Equatable, Sendable {
        public var effort: String
        public var input: Int
        public var actual: Int

        public init(effort: String, input: Int, actual: Int) {
            (self.effort, self.input, self.actual) = (effort, input, actual)
        }
    }

    // ponytail: defaults from two measured runs (a 470-token diff used 32k at low, 109k at high, almost all of it
    // Claude Code's cached system prompt and the agent's own turns); the rest is interpolated. Past runs refine it.
    /// `/code-review`'s fixed cost per effort, and how many times over the PR's input it reads (repeat reads across
    /// the agent's turns, mostly from the prompt cache).
    static let codeReviewBase: [String: (base: Int, perInput: Double)] = [
        "low": (30_000, 3), "medium": (60_000, 5), "high": (100_000, 8), "xhigh": (150_000, 10), "max": (200_000, 12),
    ]
    /// Without past runs, the range around the default: from 0.6× to 1.6× of it.
    static let defaultSpread = (low: 0.6, high: 1.6)
    /// Past runs at the same effort needed before they set the range, and how many recent ones count.
    static let samplesNeeded = 3, samplesUsed = 10

    /// The built-in guess for `/code-review` on `input` tokens of diff, description and rules.
    static func codeReviewCenter(input: Int, effort: String) -> Double {
        let model = codeReviewBase[effort] ?? codeReviewBase["high"]!
        return Double(model.base) + Double(input) * model.perInput
    }

    /// `/code-review` with `input` tokens of PR material. Once there are a few past runs at this effort, the range is
    /// the spread of their actual/default ratios applied to this PR's default, so it follows how this machine's runs go.
    public static func codeReview(input: Int, effort: String, history: [Sample] = []) -> TokenEstimate {
        let center = codeReviewCenter(input: input, effort: effort)
        let ratios = history.filter { $0.effort == effort && $0.actual > 0 }.suffix(samplesUsed)
            .map { Double($0.actual) / codeReviewCenter(input: $0.input, effort: effort) }
        guard ratios.count >= samplesNeeded, let lowest = ratios.min(), let highest = ratios.max() else {
            return TokenEstimate(low: Int(center * defaultSpread.low), high: Int(center * defaultSpread.high))
        }
        return TokenEstimate(low: Int(center * lowest), high: Int(center * highest), calibrated: true)
    }

    // ponytail: measured with a one-word prompt: Claude Code (tools off) adds ~2.6k tokens, Codex ~15k; Ollama runs
    // locally with no system prompt to speak of. Answers are budgeted per kind of prompt below.
    static func overhead(_ engine: AIEngine) -> Int {
        switch engine {
        case .claudeCode, .claudeSession: 2_600
        case .codex: 15_000
        case .ollama: 200
        }
    }

    /// The kinds of answer a prompt asks for, which bound its output.
    public enum Answer: Sendable {
        /// Findings, key areas and risk answers.
        case review
        /// A verdict per request.
        case followUp
        /// A plan per piece of feedback: steps and a reply each.
        case fixPlan
        /// A chat reply.
        case chat

        var tokens: (low: Int, high: Int) {
            switch self {
            case .review: (1_500, 6_000)
            case .followUp: (500, 3_000)
            case .fixPlan: (1_000, 6_000)
            case .chat: (200, 1_500)
            }
        }
    }

    /// A prompt the app builds and sends as is (Codex/Ollama reviews, follow-up checks, Explain/Ask).
    public static func prompt(_ text: String, engine: AIEngine, answer: Answer) -> TokenEstimate {
        prompt(tokens: AIContext.estimateTokens(text), engine: engine, answer: answer)
    }

    public static func prompt(tokens input: Int, engine: AIEngine, answer: Answer) -> TokenEstimate {
        let fixed = input + overhead(engine)
        return TokenEstimate(low: fixed + answer.tokens.low, high: fixed + answer.tokens.high)
    }
}

extension AIRun {
    /// This run as a calibration sample, when it was a `/code-review` that recorded both its estimate and its usage.
    /// A self-review's agents run without `/code-review`, so they'd skew it.
    public var sample: TokenEstimator.Sample? {
        guard ranCodeReview, agents == nil, let options, let input = estimatedTokens, let usage else { return nil }
        return TokenEstimator.Sample(effort: options.effort, input: input, actual: usage.total)
    }
}
