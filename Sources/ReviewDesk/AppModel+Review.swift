import Foundation
import ReviewDeskCore

/// Inline drafts plus the overall review text, per PR.
struct ReviewDrafts: Codable, Equatable {
    var drafts: [Draft] = []
    /// PR id → body of the review to publish.
    var bodies: [String: String] = [:]
}

extension AppModel {
    func drafts(for prID: String) -> [Draft] {
        reviewDrafts.drafts.filter { $0.prID == prID }.sorted { ($0.anchor.path, $0.anchor.line) < ($1.anchor.path, $1.anchor.line) }
    }

    func loadFiles(_ pr: PullRequest) async {
        do {
            files[pr.id] = try await github.files(pr.ref)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func addDraft(_ pr: PullRequest, anchor: Anchor, body: String) {
        reviewDrafts.drafts.append(Draft(prID: pr.id, anchor: anchor, body: body, commitOID: pr.headRefOid))
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

    /// Saves the chosen drafts into the viewer's pending review on GitHub.
    func saveDrafts(_ ids: Set<UUID>, pr: PullRequest) async {
        let selected = reviewDrafts.drafts.filter { ids.contains($0.id) }
        do {
            let saved = try await reviewSync.save(selected, pr: pr)
            for draft in saved {
                if let index = reviewDrafts.drafts.firstIndex(where: { $0.id == draft.id }) { reviewDrafts.drafts[index] = draft }
            }
        } catch {
            lastError = error.localizedDescription
        }
        await afterOwnWrite(pr)
    }

    /// Deletes locally and, if it was saved, from the pending review.
    func deleteDraft(_ draft: Draft, pr: PullRequest) async {
        do {
            try await reviewSync.delete(draft)
            deleteLocalDraft(draft.id)
        } catch {
            lastError = error.localizedDescription
        }
        await afterOwnWrite(pr)
    }

    /// The user checked an outdated draft still points at the right line.
    func keepDraftAtHead(_ id: UUID, pr: PullRequest) {
        guard let index = reviewDrafts.drafts.firstIndex(where: { $0.id == id }) else { return }
        reviewDrafts.drafts[index].isStale = false
        reviewDrafts.drafts[index].commitOID = pr.headRefOid
    }

    func publish(_ pr: PullRequest, event: ReviewEvent) async -> Bool {
        defer { Task { await afterOwnWrite(pr) } }
        do {
            try await reviewSync.publish(pr: pr, event: event, body: reviewDrafts.bodies[pr.id] ?? "", viewer: viewer)
            // Saved drafts are now published comments; local-only ones stay for later.
            reviewDrafts.drafts.removeAll { $0.prID == pr.id && $0.remoteID != nil }
            reviewDrafts.bodies[pr.id] = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func reply(to threadID: String, body: String, pr: PullRequest) async -> Bool {
        defer { Task { await afterOwnWrite(pr) } }
        do {
            try await reviewSync.reply(threadID: threadID, body: body, viewer: viewer)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Our own writes shouldn't come back as notifications: re-read the PR and move its checkpoint.
    func afterOwnWrite(_ pr: PullRequest) async {
        if let fresh = try? await github.pullRequests(ids: [pr.id]).first {
            prs[fresh.id] = fresh
            checkpoints[fresh.id] = Snapshot(fresh, viewer: viewer)
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
        let unsaved = drafts(for: pr.id).filter { $0.needsSync && !$0.isStale }
        if !unsaved.isEmpty {
            await saveDrafts(Set(unsaved.map(\.id)), pr: pr)
            guard drafts(for: pr.id).allSatisfy({ !$0.needsSync || $0.isStale }) else { return false }
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

    static func + (a: ReviewStatus, b: ReviewStatus) -> ReviewStatus {
        ReviewStatus(toSend: a.toSend + b.toSend, hasPendingReview: a.hasPendingReview || b.hasPendingReview,
                     submitted: nil, awaitingReply: a.awaitingReply + b.awaitingReply)
    }
}

extension AppModel {
    func reviewStatus(_ pr: PullRequest) -> ReviewStatus {
        // Synced drafts are already counted in the pending review's comments.
        let local = reviewDrafts.drafts.filter { $0.prID == pr.id && $0.remoteID == nil }.count
        return ReviewStatus(
            toSend: local + (pr.pendingReviewComments ?? 0),
            hasPendingReview: pr.pendingReviewComments != nil || local > 0,
            submitted: pr.viewerReviewState,
            awaitingReply: pr.threadsAwaitingReply
        )
    }
}
