import Foundation
import ReviewDeskCore

extension AppModel {
    func fixPlanRuns(for prID: String) -> [FixPlanRun] {
        fixPlans.filter { $0.prID == prID }.sorted { $0.date > $1.date }
    }

    /// The tab `pr` opens on when the chosen one isn't in `tabs`: Fix Plan on the viewer's own open PR while it has
    /// feedback to address (the polled replies owed stand in until the conversation loads), else the first tab.
    func defaultTab(_ pr: PullRequest, tabs: [DetailTab]) -> DetailTab {
        let open = fixPlanFeedback(pr).map { !$0.isEmpty } ?? (pr.threadsAwaitingReply > 0)
        return tabs.contains(.fixPlan) && pr.state == "OPEN" && open ? .fixPlan : tabs.first ?? .conversation
    }

    /// What reviewers left on the viewer's pull request that still needs an answer; nil until its detail is loaded.
    func fixPlanFeedback(_ pr: PullRequest) -> FixPlanFeedback? {
        details[pr.id].map { FixPlan.feedback(in: $0, viewer: viewer(for: pr)) }
    }

    /// Why the plan no longer matches the pull request (a push, new feedback), or nil when it's current.
    func fixPlanOutdatedReason(_ run: FixPlanRun, pr: PullRequest) -> String? {
        FixPlan.outdatedReason(run, pr: prs[pr.id] ?? pr, feedback: fixPlanFeedback(pr), viewer: viewer(for: pr))
    }

    /// The diffs a plan sends: the whole PR's when they fit `budget`, else the files the feedback points at.
    /// Prepare Context shows them for Codex and Ollama; Claude Code gets them straight away, like a follow-up check.
    func fixPlanContext(_ pr: PullRequest, budget: Int) async throws -> (context: ReviewContext, partial: Bool) {
        if pr.isDemo { throw DemoError.readOnly }
        if files[pr.id] == nil { try await fetchFiles(pr) }
        if details[pr.id] == nil { await loadDetail(pr.id) }
        guard let feedback = fixPlanFeedback(pr) else { throw AIError.failed("Couldn't load the pull request's conversation") }
        return FixPlan.changes(pr: pr, body: details[pr.id]?.body ?? "", files: files[pr.id] ?? [], feedback: feedback, budget: budget)
    }

    /// Plans how to address the feedback, tool-less, with `engine` and `options`' model and effort (`aiOptions`).
    /// `prepared` is the context Prepare Context showed, as the viewer left it; nil builds it here.
    func startFixPlan(_ pr: PullRequest, engine: AIEngine, options: AIOptions,
                      prepared: (context: ReviewContext, partial: Bool)? = nil) {
        guard !blockDemo(pr) else { return }
        aiTasks[pr.id]?.cancel()
        aiTasks[pr.id] = Task {
            aiStatus[pr.id] = "Planning fixes with \(engine.name)…"
            aiActivity[pr.id] = []
            await fixPlan(pr, engine: engine, options: options, prepared: prepared)
            aiStatus[pr.id] = nil
            aiActivity[pr.id] = nil
            aiTasks[pr.id] = nil
        }
    }

    private func fixPlan(_ pr: PullRequest, engine: AIEngine, options: AIOptions,
                         prepared: (context: ReviewContext, partial: Bool)?) async {
        do {
            // The latest feedback, so the plan answers what's open now and its markers match what was sent.
            await loadDetail(pr.id)
            guard let detail = details[pr.id], let feedback = fixPlanFeedback(pr) else { return }
            guard !feedback.isEmpty else {
                lastError = "No open feedback to plan for"
                return
            }
            let threads = feedback.threads.count, reviews = feedback.reviews.count
            logStep("\(threads) open thread\(threads == 1 ? "" : "s") and \(reviews) review summar\(reviews == 1 ? "y" : "ies") to address", pr: pr.id)
            let changes: (context: ReviewContext, partial: Bool)
            if let prepared {
                changes = prepared
            } else {
                changes = try await fixPlanContext(pr, budget: UserDefaults.standard.object(forKey: "aiBudget") as? Int ?? 150_000)
            }
            logStep(changes.partial ? "The whole diff is over the budget: sending the files the feedback points at" : "Sending the whole diff", pr: pr.id)
            logStep("Asking \(engine.name)…", pr: pr.id)
            let author = viewer(for: pr)
            let prompt = FixPlan.prompt(title: pr.title, body: detail.body, author: author, feedback: feedback, changes: changes.context,
                                        partial: changes.partial, instructions: Prompts.fixPlan)
            let meter = UsageMeter()
            let result = try await reviewer.structured(engine, prompt: prompt, schema: FixPlan.schema, as: FixPlanResult.self,
                                                       options: options, usage: meter)
            var run = FixPlanRun(prID: pr.id, engine: engine, headRefOid: pr.headRefOid, feedback: feedback.markers(viewer: author),
                                 result: FixPlan.validated(result, files: files[pr.id] ?? []))
            run.options = options
            run.partialDiff = changes.partial
            run.usage = meter.usage
            fixPlans.append(run)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { report(error, engine.name) }
        }
    }

    /// The viewer's choices for `run`'s items: only those made on the plan's head count.
    func fixPlanChoices(for run: FixPlanRun) -> [String: FixPlanChoice] {
        (fixPlanChoices[run.prID] ?? [:]).filter { $0.value.head == run.headRefOid }
    }

    /// Changes the viewer's choice for one item of `run` (its feedback id), dropping choices from other heads.
    func setFixPlanChoice(_ run: FixPlanRun, item: String, _ change: (inout FixPlanChoice) -> Void) {
        fixPlanChoices[run.prID] = FixPlan.choices(fixPlanChoices[run.prID] ?? [:], setting: item, head: run.headRefOid, change)
    }

    func deleteFixPlan(_ id: UUID) {
        fixPlans.removeAll { $0.id == id }
    }
}
