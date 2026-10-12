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
