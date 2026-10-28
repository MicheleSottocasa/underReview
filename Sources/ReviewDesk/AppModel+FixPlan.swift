import Foundation
import ReviewDeskCore

/// The feedback still to address on one of the viewer's open PRs, as the sidebar shows it.
struct ToAddress: Equatable {
    var count = 0
    /// Who left it.
    var reviewers: [String] = []
    /// The conversation is loaded, so review summaries that only comment are counted too.
    var loaded = false
}

extension AppModel {
    func fixPlanRuns(for prID: String) -> [FixPlanRun] {
        fixPlans.filter { $0.prID == prID }.sorted { $0.date > $1.date }
    }

    /// The tab `pr` opens on when the chosen one isn't in `tabs`: Fix Plan on the viewer's own open PR while it has
    /// feedback to address, else the first tab.
    func defaultTab(_ pr: PullRequest, tabs: [DetailTab]) -> DetailTab {
        tabs.contains(.fixPlan) && toAddress(pr).count > 0 ? .fixPlan : tabs.first ?? .conversation
    }

    /// Feedback still to address on the viewer's own open PR. Threads come from the polled list, which is always
    /// current; review summaries from the conversation once it's loaded (it isn't reloaded for PRs not on screen),
    /// and until then each reviewer asking for changes counts.
    func toAddress(_ pr: PullRequest) -> ToAddress {
        guard pr.viewerIsAuthor, pr.state == "OPEN" else { return ToAddress() }
        guard let feedback = fixPlanFeedback(pr) else {
            let names = pr.reviewsByOthers.filter { $0.value == "CHANGES_REQUESTED" || $0.value == "COMMENTED" }.keys.sorted()
            return ToAddress(count: pr.feedbackToAddress, reviewers: names)
        }
        let me = viewer(for: pr)
        let threads = pr.threadsToAddress ?? feedback.threads.count
        let names = feedback.threads.flatMap { $0.comments.map(\.author) } + feedback.reviews.map(\.author)
            + feedback.findings.map { "AI review (\($0.reviewer))" }
        let reviewers = names.filter { $0 != me }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return ToAddress(count: threads + feedback.reviews.count + feedback.findings.count, reviewers: reviewers, loaded: true)
    }

    /// The latest fix plan of the viewer's open PR no longer matches it: a push, or new feedback once the conversation
    /// is loaded. ponytail: before that, only a push shows; the polled list doesn't say which threads got comments.
    func hasOutdatedFixPlan(_ pr: PullRequest) -> Bool {
        // Every sidebar row asks on every redraw: one pass for the latest plan, no sort.
        guard pr.viewerIsAuthor, pr.state == "OPEN", let run = fixPlans.filter({ $0.prID == pr.id }).max(by: { $0.date < $1.date }) else { return false }
        return FixPlan.outdatedReason(run, pr: pr, feedback: fixPlanFeedback(pr), viewer: viewer(for: pr)) != nil
    }

    /// What reviewers left on the viewer's pull request that still needs an answer, plus the findings of the AI review
    /// run on one of its last commits; nil until its detail is loaded.
    func fixPlanFeedback(_ pr: PullRequest) -> FixPlanFeedback? {
        details[pr.id].map { detail in
            let commits = detail.commits.isEmpty ? [(prs[pr.id] ?? pr).headRefOid] : detail.commits.map(\.oid)
            return FixPlan.feedback(in: detail, viewer: viewer(for: pr), findings: FixPlan.aiFindings(aiRuns, prID: pr.id, commits: commits))
        }
    }

    /// Every AI finding a plan of `pr` may point at, dismissed or from an older review too, to show its items.
    func fixPlanFindings(_ pr: PullRequest) -> [FixPlanAIFinding] {
        aiRuns.filter { $0.prID == pr.id }.flatMap(FixPlanAIFinding.all(in:))
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
            let threads = feedback.threads.count, reviews = feedback.reviews.count, findings = feedback.findings.count
            logStep("\(threads) open thread\(threads == 1 ? "" : "s"), \(reviews) review summar\(reviews == 1 ? "y" : "ies") and "
                    + "\(findings) AI review finding\(findings == 1 ? "" : "s") to address", pr: pr.id)
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

    /// Posts the replies one at a time, each showing its spinner until the single reload at the end: in their thread,
    /// or as a pull request comment for a review's summary. Each one sent is marked posted on its item, so it isn't
    /// sent twice; a failure doesn't stop the others, and the banner names the ones that didn't go.
    func postFixPlanReplies(_ replies: [FixPlanReply], run: FixPlanRun, pr: PullRequest) async {
        guard !blockDemo(pr) else { return }
        let replies = replies.filter { pending.insert($0.sourceID).inserted }
        defer { for reply in replies { pending.remove(reply.sourceID) } }
        var failures: [String] = []
        for reply in replies {
            do {
                if let thread = reply.threadID {
                    try await reviewSync.reply(threadID: thread, body: reply.body, viewer: viewer)
                } else {
                    try await reviewSync.comment(prID: pr.id, body: reply.body, viewer: viewer)
                }
                setFixPlanChoice(run, item: reply.sourceID) { $0.posted = true }
            } catch {
                if let message = error.userMessage { failures.append("\(reply.label): \(message)") }
            }
        }
        await afterOwnWrite(pr)
        if !failures.isEmpty {
            lastError = "Couldn't post \(failures.count) of \(replies.count) replies: " + failures.joined(separator: "; ")
        }
    }

    /// The branch the repo's linked clone is on; nil without a linked clone, or when git can't tell.
    func cloneBranch(_ pr: PullRequest) async -> String? {
        guard !pr.isDemo, let path = localClones[pr.repo] else { return nil }
        return await clones.currentBranch(in: URL(fileURLWithPath: path))
    }

    /// Fetches what changed from the plan's head to the current one, once per pair of heads (commits never change),
    /// for the *maybe done* flags. A failure (a force-push dropped the plan's head) just leaves the flags off.
    func loadFixPlanChanges(_ run: FixPlanRun, pr: PullRequest) async {
        let current = prs[pr.id] ?? pr
        let key = Self.comparisonKey(current, base: run.headRefOid, head: current.headRefOid)
        guard !current.isDemo, !current.headRefOid.isEmpty, run.headRefOid != current.headRefOid, comparisons[key] == nil else { return }
        if let changes = try? await github.compareFiles(repo: current.repo, from: run.headRefOid, to: current.headRefOid) {
            comparisons[key] = changes
        }
    }

    /// Ids of the plan's code changes whose lines changed in a push since the plan; empty until that's loaded.
    func fixPlanMaybeDone(_ run: FixPlanRun, pr: PullRequest) -> Set<String> {
        let current = prs[pr.id] ?? pr
        guard run.headRefOid != current.headRefOid,
              let changes = comparisons[Self.comparisonKey(current, base: run.headRefOid, head: current.headRefOid)] else { return [] }
        return FixPlan.maybeDone(run.result.items, changes: changes)
    }

    func deleteFixPlan(_ id: UUID) {
        fixPlans.removeAll { $0.id == id }
    }
}
