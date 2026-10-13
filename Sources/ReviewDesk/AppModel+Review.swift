import Foundation
import ReviewDeskCore

/// Inline drafts plus the overall review text, per PR.
struct ReviewDrafts: Codable, Equatable {
    var drafts: [Draft] = []
    /// PR id → body of the review to publish.
    var bodies: [String: String] = [:]

    /// What may be saved: everything but the tour's demo.
    func removingDemo() -> ReviewDrafts {
        ReviewDrafts(drafts: drafts.filter { !Demo.owns($0.prID) }, bodies: bodies.filter { !Demo.owns($0.key) })
    }
}

extension AppModel {
    func drafts(for prID: String) -> [Draft] {
        reviewDrafts.drafts.filter { $0.prID == prID }.sorted { ($0.anchor.path, $0.anchor.line) < ($1.anchor.path, $1.anchor.line) }
    }

    /// The latest AI review with key areas or risk answers; its line numbers may predate the current head.
    func keyAreasRun(for pr: PullRequest) -> AIRun? {
        runs(for: pr.id).first { !$0.result.keyAreas.isEmpty || !$0.result.risks.isEmpty }
    }

    /// Runs the risk analysis with the AI tab's engine. Claude Code starts `/code-review` with the last used model
    /// and effort; Codex and Ollama go to the AI tab, where the context is shown before anything is sent.
    func runRiskAnalysis(_ pr: PullRequest) {
        guard !blockDemo(pr) else { return }
        let engine = preferredEngine(for: pr)
        guard engine.tool == "claude" else {
            detailTab = .ai
            return
        }
        let defaults = UserDefaults.standard
        startCodeReview(pr, engine: engine, options: CodeReviewOptions(model: defaults.string(forKey: "claudeModel") ?? "",
                                                                      effort: defaults.string(forKey: "reviewEffort") ?? "high"))
    }

    /// What to read before submitting: the AI's key areas, then files with comments not submitted yet.
    func focus(for pr: PullRequest) -> [FocusFile] {
        let drafts = drafts(for: pr.id)
        let synced = Set(drafts.compactMap(\.remoteID))
        let pendingOnGitHub = details[pr.id]?.pendingReview?.comments.filter { !synced.contains($0.id) }.map(\.path) ?? []
        return Focus.files(keyAreas: keyAreasRun(for: pr)?.result.keyAreas ?? [], pendingPaths: drafts.map(\.anchor.path) + pendingOnGitHub,
                           changed: files[pr.id]?.map(\.filename) ?? [])
    }

    /// Opens Changes at a file, scrolled to `line` when given (an old-file line when `side` is left).
    func openInChanges(_ path: String, line: Int?, side: DiffSide = .right, pr: PullRequest) {
        changesTarget = LineTarget(path: path, line: line ?? 0, side: side)
        detailTab = .changes
    }

    /// The commit a risk question was checked at, if it was.
    func riskCheck(_ question: RiskQuestion, pr: PullRequest) -> String? {
        riskChecks[pr.id]?[question.rawValue]
    }

    /// Checking stores the current head, so a later push shows the check as stale.
    func setRiskCheck(_ question: RiskQuestion, checked: Bool, pr: PullRequest) {
        riskChecks[pr.id, default: [:]][question.rawValue] = checked ? pr.headRefOid : nil
        if riskChecks[pr.id]?.isEmpty == true { riskChecks[pr.id] = nil }
    }

    /// Question 5 as a line in the review summary, so it's posted with the review.
    static let explainRequest = "Could you explain the approach in two or three sentences?"

    func askAuthorToExplain(_ pr: PullRequest) {
        let body = reviewDrafts.bodies[pr.id] ?? ""
        guard !body.contains(Self.explainRequest) else { return }
        reviewDrafts.bodies[pr.id] = body.isEmpty ? Self.explainRequest : body + "\n\n" + Self.explainRequest
    }

    func loadFiles(_ pr: PullRequest) async {
        guard !pr.isDemo else { return } // canned in the demo
        do {
            async let viewed = github.viewedFiles(prID: pr.id)
            files[pr.id] = try await github.files(pr.ref)
            viewedFiles[pr.id] = try await viewed
        } catch {
            report(error)
        }
    }

    /// Flips the file's Viewed checkbox here and on GitHub, rolling back if GitHub refuses.
    func toggleViewed(_ path: String, pr: PullRequest) async {
        guard !blockDemo(pr) else { return }
        await whilePending("\(pr.id):\(path)") {
            let viewed = !(viewedFiles[pr.id]?.contains(path) ?? false)
            viewedFiles[pr.id, default: []].formSymmetricDifference([path])
            do {
                try await github.setViewed(prID: pr.id, path: path, viewed: viewed)
            } catch {
                viewedFiles[pr.id, default: []].formSymmetricDifference([path])
                report(error)
            }
        }
    }

    @discardableResult
    func addDraft(_ pr: PullRequest, anchor: Anchor, body: String, startLine: Int? = nil) -> UUID {
        var draft = Draft(prID: pr.id, anchor: anchor, body: body, commitOID: pr.headRefOid)
        draft.startLine = startLine
        reviewDrafts.drafts.append(draft)
        return draft.id
    }

    func updateDraft(_ id: UUID, body: String) {
        guard let index = reviewDrafts.drafts.firstIndex(where: { $0.id == id }) else { return }
        reviewDrafts.drafts[index].body = body
    }

    func deleteLocalDraft(_ id: UUID) {
        reviewDrafts.drafts.removeAll { $0.id == id }
    }
}

extension AppModel {
    var reviewSync: ReviewSync { ReviewSync(github: github) }

    /// Saves the chosen drafts into the viewer's pending review on GitHub. `reload: false` when another write follows.
    func saveDrafts(_ ids: Set<UUID>, pr: PullRequest, reload: Bool = true) async {
        guard !blockDemo(pr) else { return }
        let selected = reviewDrafts.drafts.filter { ids.contains($0.id) }
        do {
            let saved = try await reviewSync.save(selected, pr: pr)
            for draft in saved {
                if let index = reviewDrafts.drafts.firstIndex(where: { $0.id == draft.id }) { reviewDrafts.drafts[index] = draft }
            }
        } catch {
            report(error)
        }
        if reload { await afterOwnWrite(pr) }
    }

    /// Deletes locally and, if it was saved, from the pending review. A saved draft stays (dimmed) until the reload,
    /// so its pending comment doesn't show up again in the meantime.
    func deleteDraft(_ draft: Draft, pr: PullRequest) async {
        guard !blockDemo(pr) else { return }
        guard draft.remoteID != nil else { return deleteLocalDraft(draft.id) }
        await whilePending(draft.id.uuidString) {
            var deleted = true
            do {
                try await reviewSync.delete(draft)
            } catch {
                report(error)
                deleted = false
            }
            await afterOwnWrite(pr)
            if deleted { deleteLocalDraft(draft.id) }
        }
    }

    /// The user checked an outdated draft still points at the right line.
    func keepDraftAtHead(_ id: UUID, pr: PullRequest) {
        guard let index = reviewDrafts.drafts.firstIndex(where: { $0.id == id }) else { return }
        reviewDrafts.drafts[index].isStale = false
        reviewDrafts.drafts[index].commitOID = pr.headRefOid
    }

    func publish(_ pr: PullRequest, event: ReviewEvent) async -> Bool {
        let published = await commentWrite(pr) {
            try await reviewSync.publish(pr: pr, event: event, body: reviewDrafts.bodies[pr.id] ?? "", viewer: viewer)
        }
        guard published else { return false }
        // Saved drafts are now published comments; local-only ones stay for later. Dropped after the reload, so
        // their comments don't show twice in the meantime.
        reviewDrafts.drafts.removeAll { $0.prID == pr.id && $0.remoteID != nil }
        reviewDrafts.bodies[pr.id] = nil
        return true
    }

    func reply(to threadID: String, body: String, pr: PullRequest) async -> Bool {
        await commentWrite(pr, pending: threadID) { try await reviewSync.reply(threadID: threadID, body: body, viewer: viewer) }
    }

    func editComment(_ comment: Comment, body: String, pr: PullRequest) async -> Bool {
        await commentWrite(pr, pending: comment.id) { try await github.editComment(comment, body: body) }
    }

    func deleteComment(_ comment: Comment, pr: PullRequest) async {
        await commentWrite(pr, pending: comment.id) { try await github.deleteComment(comment) }
    }

    /// Adds the reaction, or removes it if the viewer already gave it.
    func toggleReaction(_ content: ReactionContent, on comment: Comment, pr: PullRequest) async {
        let reacted = comment.reactions.contains { $0.content == content && $0.viewerHasReacted }
        await commentWrite(pr, pending: comment.id) { try await github.setReaction(content, on: comment.id, reacted: !reacted) }
    }

    func setResolved(_ thread: ReviewThread, _ resolved: Bool, pr: PullRequest) async {
        await commentWrite(pr, pending: thread.id) { try await github.setResolved(threadID: thread.id, resolved: resolved) }
    }

    func setHiddenAsResolved(_ comment: Comment, _ hidden: Bool, pr: PullRequest) async {
        await commentWrite(pr, pending: comment.id) { try await github.setHiddenAsResolved(commentID: comment.id, hidden: hidden) }
    }

    /// Writes, then waits for the PR to reload (even after a failure), so callers' progress lasts until the new state shows.
    @discardableResult
    private func commentWrite(_ pr: PullRequest, pending id: String? = nil, _ write: () async throws -> Void) async -> Bool {
        guard !blockDemo(pr) else { return false }
        func run() async -> Bool {
            let succeeded: Bool
            do {
                try await write()
                succeeded = true
            } catch {
                report(error)
                succeeded = false
            }
            await afterOwnWrite(pr)
            return succeeded
        }
        guard let id else { return await run() }
        return await whilePending(id) { await run() } ?? false
    }

    /// Our own writes shouldn't come back as notifications: re-read the PR and move its checkpoint.
    func afterOwnWrite(_ pr: PullRequest) async {
        if let fresh = try? await github.pullRequests(ids: [pr.id]).first {
            prs[fresh.id] = fresh
            Updates.acknowledgeOwnWrite(&checkpoints, pr: fresh, viewer: viewer)
        }
        await loadDetail(pr.id)
    }

    /// After a push, flag drafts whose file changed.
    func refreshStaleDrafts(_ prs: [PullRequest]) async {
        for pr in prs {
            let drafts = drafts(for: pr.id)
            guard drafts.contains(where: { $0.commitOID != pr.headRefOid && !$0.isStale }) else { continue }
            for draft in await reviewSync.refreshStaleness(drafts, pr: pr) {
                if let index = reviewDrafts.drafts.firstIndex(where: { $0.id == draft.id }) { reviewDrafts.drafts[index] = draft }
            }
            files[pr.id] = nil
        }
    }
}

extension AppModel {
    /// Like GitHub's Submit: local drafts join the pending review first, then it's submitted with the chosen action.
    func submitReview(_ pr: PullRequest, event: ReviewEvent) async -> Bool {
        guard !blockDemo(pr) else { return false }
        let unsaved = drafts(for: pr.id).filter { $0.needsSync && !$0.isStale }
        if !unsaved.isEmpty {
            // Publishing reloads the PR anyway; only a failed save needs its own reload.
            await saveDrafts(Set(unsaved.map(\.id)), pr: pr, reload: false)
            guard drafts(for: pr.id).allSatisfy({ !$0.needsSync || $0.isStale }) else {
                await afterOwnWrite(pr)
                return false
            }
        }
        return await publish(pr, event: event)
    }
}

/// Where the viewer stands on a PR, shown in the sidebar without opening it.
struct ReviewStatus: Equatable {
    /// Local drafts not on GitHub yet plus comments in the pending GitHub review.
    var toSend = 0
    /// An unsubmitted review exists on GitHub (possibly with only a summary).
    var hasPendingReview = false
    /// Latest submitted review state, when nothing is waiting to be sent.
    var submitted: String?
    var awaitingReply = 0
    /// New commits since the viewer's review.
    var changedSinceReview = false
    /// The latest AI analysis predates the author's latest push.
    var outdatedAnalysis = false

    static func + (a: ReviewStatus, b: ReviewStatus) -> ReviewStatus {
        ReviewStatus(toSend: a.toSend + b.toSend, hasPendingReview: a.hasPendingReview || b.hasPendingReview,
                     submitted: nil, awaitingReply: a.awaitingReply + b.awaitingReply,
                     changedSinceReview: a.changedSinceReview || b.changedSinceReview,
                     outdatedAnalysis: a.outdatedAnalysis || b.outdatedAnalysis)
    }
}

extension AppModel {
    func reviewStatus(_ pr: PullRequest) -> ReviewStatus {
        // Synced drafts are already counted in the pending review's comments.
        let local = reviewDrafts.drafts.filter { $0.prID == pr.id && $0.remoteID == nil }.count
        return ReviewStatus(
            toSend: local + (pr.pendingReviewComments ?? 0),
            hasPendingReview: pr.pendingReviewComments != nil || local > 0,
            // Replying on your own PR files a "commented" review; its row shows the reviews others left instead.
            submitted: pr.viewerIsAuthor ? nil : pr.viewerReviewState,
            awaitingReply: pr.threadsAwaitingReply,
            changedSinceReview: pr.needsReReview,
            outdatedAnalysis: hasOutdatedAnalysis(pr)
        )
    }
}
