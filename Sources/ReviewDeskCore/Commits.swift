import Foundation

/// What Changes shows: the whole pull request, what changed since the viewer's last review, or a run of commits.
public enum CommitSelection: Hashable, Sendable {
    case all, sinceReview
    /// Oldest and newest commit of the run, both included; the same commit for a single one.
    case range(first: String, last: String)

    /// The two commits to compare, or nil for the whole pull request (also when the selection no longer applies).
    public func bounds(commits: [PRCommit], pr: PullRequest) -> (base: String, head: String)? {
        switch self {
        case .all:
            return nil
        case .sinceReview:
            guard let reviewed = pr.viewerReviewedOid, reviewed != pr.headRefOid else { return nil }
            return (reviewed, pr.headRefOid)
        case .range(let first, let last):
            // From the first commit's parent: GitHub's compare takes `sha^`, so the parent needn't be fetched with
            // every commit (that doubled the detail query's cost). A root commit has none: compare fails, whole diff.
            // ponytail: a merge inside the range brings in its side branch's changes too, as `git diff first^ last` does;
            // walking parent links would need the parents fetched again, which is what made the query cost double.
            guard commits.contains(where: { $0.oid == first }), commits.contains(where: { $0.oid == last }) else { return nil }
            return (first + "^", last)
        }
    }

    /// The selection made when the head was `head`: a push resets it to the whole pull request, except
    /// *since my last review*, which follows the head.
    public func current(chosenAt head: String, pr: PullRequest) -> CommitSelection {
        self == .sinceReview || head == pr.headRefOid ? self : .all
    }
}

/// A diff of some commits next to the whole pull request's diff, which GitHub anchors every review comment to.
public struct CommitView: Sendable {
    /// The compared range ends at the pull request's head, so new-side line numbers are the PR diff's.
    public var endsAtHead: Bool
    /// The file's anchors in the PR diff.
    public var prAnchors: Set<Anchor>

    public init(endsAtHead: Bool, prAnchors: Set<Anchor>) {
        self.endsAtHead = endsAtHead
        self.prAnchors = prAnchors
    }

    /// Threads and drafts anchored here sit on the same line in this view: the new side of a range ending at the head.
    /// Old-side numbers count from a different base, so they never match.
    public func shows(_ anchor: Anchor) -> Bool { endsAtHead && anchor.side == .right }

    /// A comment on this line of the view can go on the pull request: it's shown here and is in the PR diff too.
    public func accepts(_ anchor: Anchor) -> Bool { shows(anchor) && prAnchors.contains(anchor) }
}
