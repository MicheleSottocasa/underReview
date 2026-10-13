import Foundation
import ReviewDeskCore

extension AppModel {
    func followUpRuns(for prID: String) -> [FollowUpRun] {
        followUps.filter { $0.prID == prID }.sorted { $0.date > $1.date }
    }

    /// The author pushed since the viewer's review, or replied to one of their open threads. Before the PR's detail
    /// is loaded, the inbox's counters stand in: reviewed and changed since, or replies waiting for the viewer.
    func isFollowUpDue(_ pr: PullRequest) -> Bool {
        guard pr.state == "OPEN" else { return false }
        if let detail = details[pr.id] { return FollowUp.isDue(pr, detail: detail, viewer: viewer) }
        return pr.needsReReview || pr.threadsAwaitingReply > 0
    }

    /// The PRs of `pr`'s stack still to review, bottom first: open and not approved by the viewer. Empty outside a stack.
    func stackMembers(of pr: PullRequest) -> [PullRequest] {
        Stacks.toReview(stackPullRequests(of: pr))
    }

    /// Every PR of `pr`'s stack, bottom first; empty when it isn't in one.
    func stackPullRequests(of pr: PullRequest) -> [PullRequest] {
        guard pr.stack != nil else { return [] }
        return allItems.first { $0.key == pr.itemKey && $0.isStack }?.pullRequests ?? []
    }

    /// Shown while this PR, or another in its stack, has something to check or a past check to read.
    func showsFollowUp(_ pr: PullRequest) -> Bool {
        let prs = stackMembers(of: pr).isEmpty ? [pr] : stackMembers(of: pr)
        return prs.contains { isFollowUpDue($0) || !followUpRuns(for: $0.id).isEmpty }
    }

    /// Checks every PR of the stack that has new commits or replies since the viewer's review, bottom first.
    /// Progress and the live log show on `current`, the PR it was started from.
    func startStackFollowUp(_ prs: [PullRequest], from current: String) {
        if let demo = prs.first(where: \.isDemo) { _ = blockDemo(demo); return }
        let engine = preferredEngine(for: prs.first(where: { $0.id == current }) ?? prs[0])
        aiTasks[current]?.cancel()
        aiTasks[current] = Task {
            aiActivity[current] = []
            defer {
                aiStatus[current] = nil
                aiActivity[current] = nil
                aiTasks[current] = nil
            }
            for (index, pr) in prs.enumerated() where !Task.isCancelled {
                aiStatus[current] = "Checking #\(pr.number) (\(index + 1) of \(prs.count)) with \(engine.name)…"
                await loadDetail(pr.id)
                guard FollowUp.isDue(pr, detail: details[pr.id], viewer: viewer) else {
                    logStep("#\(pr.number): nothing new since your review, skipped", pr: current)
                    continue
                }
                logStep("#\(pr.number) \(pr.title)", pr: current)
                await followUp(pr, engine: engine, key: current)
            }
            logStep("Stack checked", pr: current)
        }
    }

    /// Asks the AI tab's engine whether the changes and replies since the viewer's review handle each of their requests.
    func startFollowUp(_ pr: PullRequest) {
        guard !blockDemo(pr) else { return }
        let engine = preferredEngine(for: pr)
        aiTasks[pr.id]?.cancel()
        aiTasks[pr.id] = Task {
            aiStatus[pr.id] = "Checking your comments with \(engine.name)…"
            aiActivity[pr.id] = []
            await followUp(pr, engine: engine, key: pr.id)
            aiStatus[pr.id] = nil
            aiActivity[pr.id] = nil
            aiTasks[pr.id] = nil
        }
    }

    /// One PR's check. `key` is the PR whose live log shows the steps (the one a stack check started from).
    private func followUp(_ pr: PullRequest, engine: AIEngine, key: String) async {
        do {
            await loadDetail(pr.id)
            guard let detail = details[pr.id] else { return }
            let threads = FollowUp.threads(of: viewer, in: detail), bodies = FollowUp.reviewBodies(of: viewer, in: detail)
            logStep("\(threads.count) open thread\(threads.count == 1 ? "" : "s") of yours, \(FollowUp.replies(to: viewer, in: detail)) with replies"
                    + (bodies.isEmpty ? "" : ", plus your review summary"), pr: key)
            // Only what changed since the review, when GitHub still has the reviewed commit.
            var changed: [FileChange]
            var sinceReview = true
            if let reviewed = pr.viewerReviewedOid, reviewed == pr.headRefOid {
                changed = []
                logStep("No new commits since your review: checking the replies", pr: key)
            } else if let reviewed = pr.viewerReviewedOid, let diff = try? await github.compareFiles(repo: pr.repo, from: reviewed, to: pr.headRefOid) {
                changed = diff
                logStep("\(diff.count) file\(diff.count == 1 ? "" : "s") changed since your review", pr: key)
            } else {
                if files[pr.id] == nil { try await fetchFiles(pr) }
                changed = files[pr.id] ?? []
                sinceReview = false
                logStep("What changed since your review isn't available: using the whole diff", pr: key)
            }
            let budget = UserDefaults.standard.object(forKey: "aiBudget") as? Int ?? 150_000
            let changes = AIContext.build(pr: pr, body: "", files: changed, contents: [:], budget: budget).fittingBudget()
            logStep("Asking \(engine.name)…", pr: key)
            let prompt = FollowUp.prompt(title: pr.title, viewer: viewer, threads: threads, reviewBodies: bodies, changes: changes,
                                         sinceReview: sinceReview, instructions: Prompts.followUp)
            let result = try await reviewer.structured(engine, prompt: prompt, schema: FollowUp.schema, as: FollowUpResult.self)
            followUps.append(FollowUpRun(prID: pr.id, engine: engine, headRefOid: pr.headRefOid,
                                         reviewedOid: sinceReview ? pr.viewerReviewedOid : nil, result: result))
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { report(error, engine.name) }
        }
    }

    func deleteFollowUp(_ id: UUID) {
        followUps.removeAll { $0.id == id }
    }
}
