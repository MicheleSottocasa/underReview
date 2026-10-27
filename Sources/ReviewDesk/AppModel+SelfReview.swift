import Foundation
import ReviewDeskCore

/// The agents' results of one self-review, gathered as they finish.
@MainActor
private final class SelfReviewParts {
    var results: [(focus: ReviewFocus, result: ReviewResult)] = []
}

extension AppModel {
    /// The id a self-review agent's state, status and log go under: one per focus, beside its PR's.
    static func selfReviewAgent(_ pr: PullRequest, _ focus: ReviewFocus) -> String { "\(pr.id)/self-review/\(focus.id)" }

    /// Reviews the viewer's own PR with one agent per focus (`SelfReview.focuses`), several at once (Settings › AI),
    /// with the Review Stack machinery: each agent's state and live log show on the PR. Every agent reads the same
    /// context (the diff, full files and repository rules, fitted to `budget`), tool-less, with `engine` and
    /// `options`' model and effort (`aiOptions`, as a follow-up check); their findings are merged into one AI Review result. Nothing is
    /// posted. Like a stack review, it runs without showing the context first, so the project's extra context stays out.
    func startSelfReview(_ pr: PullRequest, engine: AIEngine, budget: Int, options: AIOptions) {
        guard !blockDemo(pr) else { return }
        let focuses = SelfReview.focuses
        let agents = focuses.map { Self.selfReviewAgent(pr, $0) }
        cancelStackRun(pr.id)
        aiTasks[pr.id]?.cancel()
        var run = StackRun(members: agents, states: Dictionary(uniqueKeysWithValues: agents.map { ($0, .waiting) }))
        run.labels = Dictionary(uniqueKeysWithValues: zip(agents, focuses.map(\.title)))
        stackRuns[pr.id] = run
        for id in agents {
            aiActivity[id] = []
            aiStatus[id] = "Waiting for a free agent…"
        }
        // ponytail: the same fixed cap as stack reviews (Settings › AI); Ollama runs one at a time on this Mac.
        let limit = engine.isLocal ? 1 : max(1, UserDefaults.standard.object(forKey: "stackParallelAgents") as? Int ?? 3)
        let parts = SelfReviewParts()
        let meter = UsageMeter()
        aiTasks[pr.id] = Task {
            defer {
                for id in agents where stackRuns[pr.id]?.states[id] == .waiting {
                    stackRuns[pr.id]?.states[id] = .cancelled
                    aiStatus[id] = nil
                }
                stackRuns[pr.id]?.isFinished = true
                aiTasks[pr.id] = nil
            }
            let context: ReviewContext
            do {
                context = try await prepareContext(pr, budget: budget, projectContext: false).fittingBudget()
            } catch {
                for id in agents {
                    stackRuns[pr.id]?.states[id] = error.userMessage.map { .failed($0) } ?? .cancelled
                    aiStatus[id] = nil
                }
                return
            }
            let left = context.files.filter { !$0.included }.count
            for id in agents where left > 0 {
                logStep("\(left) file\(left == 1 ? "" : "s") over the token budget left out; review the PR on its own to choose", pr: id)
            }
            await Parallel.run(Array(zip(focuses, agents)), limit: limit) { focus, id in
                let agent = Task {
                    await self.reviewFocus(pr, focus: focus, agent: id, engine: engine, options: options, context: context,
                                           parts: parts, meter: meter)
                }
                aiTasks[id] = agent
                return agent
            }
            guard !Task.isCancelled, !parts.results.isEmpty else { return }
            let done = focuses.compactMap { focus in parts.results.first { $0.focus == focus } }
            var review = AIRun(prID: pr.id, engine: engine, headRefOid: pr.headRefOid,
                               result: SelfReview.merge(done, missing: focuses.filter { focus in !done.contains { $0.focus == focus } }))
            review.options = options
            // ReviewDesk's prompt, whatever the review command: not a `/code-review` to calibrate estimates with.
            review.command = ReviewCommand.generic.label(saved: reviewTemplates)
            review.agents = done.map(\.focus.title)
            review.usage = meter.usage
            aiRuns.append(review)
        }
    }

    /// One self-review agent: the shared context, the review prompt with its focus, and no tools.
    private func reviewFocus(_ pr: PullRequest, focus: ReviewFocus, agent id: String, engine: AIEngine, options: AIOptions,
                             context: ReviewContext, parts: SelfReviewParts, meter: UsageMeter) async {
        guard !Task.isCancelled, stackRuns[pr.id]?.states[id] == .waiting else { return } // stopped before its turn
        stackRuns[pr.id]?.states[id] = .running
        aiStatus[id] = "Reviewing \(focus.title.lowercased()) with \(engine.name)…"
        logStep("Asking \(engine.name), without tools…", pr: id)
        do {
            let prompt = AIContext.prompt(context, instructions: SelfReview.instructions(Prompts.review, focus: focus))
            let result = try await reviewer.structured(engine, prompt: prompt, schema: AIContext.schema, as: ReviewResult.self,
                                                       options: options, usage: meter)
            parts.results.append((focus, result))
            stackRuns[pr.id]?.states[id] = .done(findings: result.findings.count)
        } catch {
            stackRuns[pr.id]?.states[id] = error.userMessage.map { .failed($0) } ?? .cancelled
            if Task.isCancelled { stackRuns[pr.id]?.states[id] = .cancelled }
        }
        aiStatus[id] = nil
        aiTasks[id] = nil
    }
}
