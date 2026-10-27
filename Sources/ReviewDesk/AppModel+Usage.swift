import Foundation
import ReviewDeskCore

/// Token estimates shown before a run, from the material the app would send and what past runs used.
extension AppModel {
    // ponytail: before a PR's files load, its size stands in at ~12 tokens per changed line (a typical diff line
    // with its +/- and context); the estimate tightens once the diff is loaded.
    static let tokensPerChangedLine = 12

    /// The PR material `/code-review` and Codex/Ollama reviews start from: title, description and diff.
    func reviewInput(_ pr: PullRequest) -> Int {
        let header = AIContext.estimateTokens(pr.title + (details[pr.id]?.body ?? ""))
        guard let files = files[pr.id] else { return header + (pr.additions + pr.deletions) * Self.tokensPerChangedLine }
        return header + files.reduce(0) { $0 + AIContext.estimateTokens($1.patch ?? "") }
    }

    /// Past `/code-review` runs that recorded their estimate and usage, oldest first, to calibrate new estimates.
    var codeReviewSamples: [TokenEstimator.Sample] {
        aiRuns.sorted { $0.date < $1.date }.compactMap(\.sample)
    }

    /// What reviewing `pr` with `engine` is likely to use. Codex and Ollama are estimated from the diff alone here;
    /// Prepare Context then shows the exact input, with the full files it adds.
    func reviewEstimate(_ pr: PullRequest, engine: AIEngine, effort: String) -> TokenEstimate {
        let input = reviewInput(pr)
        return reviewCommand(for: engine) == .codeReview ? TokenEstimator.codeReview(input: input, effort: effort, history: codeReviewSamples)
            : TokenEstimator.prompt(tokens: input, engine: engine, answer: .review)
    }

    func reviewEstimate(_ prs: [PullRequest], engine: AIEngine, effort: String) -> TokenEstimate? {
        TokenEstimate.sum(prs.map { reviewEstimate($0, engine: engine, effort: effort) })
    }

    /// A follow-up check's ceiling: the viewer's open threads and review summary, plus the whole PR diff (only the part
    /// changed since their review is sent, so the real input is usually smaller). Nil until the PR's detail is loaded.
    func followUpEstimate(_ pr: PullRequest, engine: AIEngine) -> TokenEstimate? {
        guard let detail = details[pr.id] else { return nil }
        let requests = FollowUp.threads(of: viewer, in: detail).flatMap(\.comments).map(\.body) + FollowUp.reviewBodies(of: viewer, in: detail)
        let input = AIContext.estimateTokens(requests.joined(separator: "\n")) + reviewInput(pr)
        return TokenEstimator.prompt(tokens: input, engine: engine, answer: .followUp)
    }

    func followUpEstimate(_ prs: [PullRequest], engine: AIEngine) -> TokenEstimate? {
        let each = prs.map { followUpEstimate($0, engine: engine) }
        guard !each.contains(where: { $0 == nil }) else { return nil }
        return TokenEstimate.sum(each.compactMap { $0 })
    }

    /// The next question in a chat: its context and the conversation so far are resent every time.
    func chatEstimate(_ chat: Explanation, question: String) -> TokenEstimate? {
        guard !chat.prompt.isEmpty else { return nil }
        let prompt = AIContext.followUpPrompt(explainPrompt: chat.prompt, chat: chat.messages, question: question)
        return TokenEstimator.prompt(prompt, engine: chat.engine, answer: .chat)
    }

    /// Hover text for a `/code-review` estimate: where its range comes from.
    func codeReviewEstimateHelp(_ estimate: TokenEstimate, effort: String) -> String {
        let runs = codeReviewSamples.filter { $0.effort == effort }.count
        return "Estimated tokens for /code-review at \(effort) effort: mostly Claude Code's own prompt and the agent's reading, "
            + "plus this pull request's diff. "
            + (estimate.calibrated ? "Fitted to your last \(min(runs, 10)) runs at this effort."
                                   : "A built-in guess until 3 runs at this effort have recorded their usage (\(runs) so far).")
            + " It counts toward your plan's limits."
    }
}
