import AppKit
import ReviewDeskCore

enum DemoError: Error, LocalizedError {
    case readOnly

    static let message = "This is the tour's demo pull request: it's read-only, and nothing in it is sent to GitHub or an AI provider."

    var errorDescription: String? { Self.message }
}

extension AppModel {
    /// The demo is read-only: true (with a message) when `pr` is part of it, so the caller stops.
    func blockDemo(_ pr: PullRequest) -> Bool {
        guard pr.isDemo else { return false }
        lastError = DemoError.message
        return true
    }

    var isDemoShown: Bool { prs[Demo.mainID] != nil }

    /// Who "you" is on `pr`: the demo's own viewer on the tour's fictional PRs, the GitHub login elsewhere.
    func viewer(for pr: PullRequest) -> String { pr.isDemo ? Demo.viewer : viewer }

    /// Puts the demo stack in memory, next to the real PRs. Saves drop it (see the `didSet`s).
    func showDemo() {
        for pr in Demo.pullRequests { prs[pr.id] = pr }
        for (id, detail) in Demo.details { details[id] = detail }
        for (id, changed) in Demo.files { files[id] = changed }
        for (id, viewed) in Demo.viewedFiles { viewedFiles[id] = viewed }
        reviewDrafts.drafts = reviewDrafts.drafts.filter { !Demo.owns($0.prID) } + Demo.drafts
        aiRuns = aiRuns.filter { !Demo.owns($0.prID) } + Demo.runs
        followUps = followUps.filter { !Demo.owns($0.prID) } + Demo.followUps
    }

    /// Removes every trace of the demo from memory, including anything the user did to it during the tour.
    func hideDemo() {
        if selectedPRID.map(Demo.owns) == true {
            selection = []
            selectedPRID = nil
        }
        prs = prs.filter { !Demo.owns($0.key) }
        details = details.filter { !Demo.owns($0.key) }
        files = files.filter { !Demo.owns($0.key) }
        viewedFiles = viewedFiles.filter { !Demo.owns($0.key) }
        reviewDrafts = reviewDrafts.removingDemo()
        aiRuns = aiRuns.filter { !Demo.owns($0.prID) }
        followUps = followUps.filter { !Demo.owns($0.prID) }
        riskChecks = riskChecks.filter { !Demo.owns($0.key) }
        org = org.removingDemo()
        checkpoints = checkpoints.filter { !Demo.owns($0.key) }
    }
}
