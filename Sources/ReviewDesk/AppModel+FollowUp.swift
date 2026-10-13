import Foundation
import ReviewDeskCore

extension AppModel {
    func followUpRuns(for prID: String) -> [FollowUpRun] {
        followUps.filter { $0.prID == prID }.sorted { $0.date > $1.date }
    }

    /// The author pushed since the viewer's review, or replied to one of their open threads.
    func isFollowUpDue(_ pr: PullRequest) -> Bool {
        FollowUp.isDue(pr, detail: details[pr.id], viewer: viewer)
    }

    /// Shown while there's something to check or a past check to read.
    func showsFollowUp(_ pr: PullRequest) -> Bool {
        isFollowUpDue(pr) || !followUpRuns(for: pr.id).isEmpty
    }

    /// Asks the AI tab's engine whether the changes and replies since the viewer's review handle each of their requests.
    func startFollowUp(_ pr: PullRequest) {
        guard !blockDemo(pr) else { return }
        let engine = preferredEngine(for: pr)
        aiTasks[pr.id]?.cancel()
        aiTasks[pr.id] = Task {
            await followUp(pr, engine: engine)
            aiTasks[pr.id] = nil
        }
    }

    private func followUp(_ pr: PullRequest, engine: AIEngine) async {
        aiStatus[pr.id] = "Checking your comments with \(engine.name)…"
        aiActivity[pr.id] = []
        defer {
            aiStatus[pr.id] = nil
            aiActivity[pr.id] = nil
        }
        do {
            await loadDetail(pr.id)
            guard let detail = details[pr.id] else { return }
            let threads = FollowUp.threads(of: viewer, in: detail), bodies = FollowUp.reviewBodies(of: viewer, in: detail)
            logStep("\(threads.count) open thread\(threads.count == 1 ? "" : "s") of yours, \(FollowUp.replies(to: viewer, in: detail)) with replies"
                    + (bodies.isEmpty ? "" : ", plus your review summary"), pr: pr.id)
            // Only what changed since the review, when GitHub still has the reviewed commit.
            var changed: [FileChange]
            var sinceReview = true
            if let reviewed = pr.viewerReviewedOid, reviewed == pr.headRefOid {
                changed = []
                logStep("No new commits since your review: checking the replies", pr: pr.id)
            } else if let reviewed = pr.viewerReviewedOid, let diff = try? await github.compareFiles(repo: pr.repo, from: reviewed, to: pr.headRefOid) {
                changed = diff
                logStep("\(diff.count) file\(diff.count == 1 ? "" : "s") changed since your review", pr: pr.id)
            } else {
                if files[pr.id] == nil { files[pr.id] = try await github.files(pr.ref) }
                changed = files[pr.id] ?? []
                sinceReview = false
                logStep("What changed since your review isn't available: using the whole diff", pr: pr.id)
            }
            let budget = UserDefaults.standard.object(forKey: "aiBudget") as? Int ?? 150_000
            let changes = AIContext.build(pr: pr, body: "", files: changed, contents: [:], budget: budget).fittingBudget()
            logStep("Asking \(engine.name)…", pr: pr.id)
            let prompt = FollowUp.prompt(title: pr.title, viewer: viewer, threads: threads, reviewBodies: bodies, changes: changes,
                                         sinceReview: sinceReview, instructions: Prompts.followUp)
            let result = try await reviewer.structured(engine, prompt: prompt, schema: FollowUp.schema, as: FollowUpResult.self)
            followUps.append(FollowUpRun(prID: pr.id, engine: engine, headRefOid: pr.headRefOid,
                                         reviewedOid: sinceReview ? pr.viewerReviewedOid : nil, result: result))
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { lastError = "\(engine.name): \(error.localizedDescription)" }
        }
    }

    func deleteFollowUp(_ id: UUID) {
        followUps.removeAll { $0.id == id }
    }
}
