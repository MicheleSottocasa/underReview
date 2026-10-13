import Foundation
import ReviewDeskCore

/// Reviewing some commits instead of the whole pull request.
extension AppModel {
    /// What Changes shows for the pull request: back to all commits after a push, unless it's *since my last review*.
    func commitSelection(for pr: PullRequest) -> CommitSelection {
        commitSelections[pr.id].map { $0.selection.current(chosenAt: $0.head, pr: pr) } ?? .all
    }

    func selectCommits(_ selection: CommitSelection, pr: PullRequest) {
        commitSelections[pr.id] = (selection, pr.headRefOid)
    }

    /// Opens Changes on one commit of the pull request.
    func openCommit(_ oid: String, pr: PullRequest) {
        selectCommits(.range(first: oid, last: oid), pr: pr)
        detailTab = .changes
    }

    static func comparisonKey(_ pr: PullRequest, base: String, head: String) -> String { "\(pr.repo)@\(base)...\(head)" }

    /// Fetches a comparison once, when it's first shown: commits never change, so it's kept for the session.
    func loadComparison(_ pr: PullRequest, base: String, head: String) async {
        let key = Self.comparisonKey(pr, base: base, head: head)
        guard comparisons[key] == nil, missingComparisons[key] == nil, !blockDemo(pr) else { return }
        do {
            comparisons[key] = try await github.compareFiles(repo: pr.repo, from: base, to: head)
        } catch is CancellationError {
        } catch GitHubError.rewritten {
            missingComparisons[key] = "Those commits were rebased or rewritten since, so the whole pull request is shown."
        } catch {
            missingComparisons[key] = "Those commits aren't on GitHub anymore (force-pushed?), so the whole pull request is shown."
        }
    }
}
