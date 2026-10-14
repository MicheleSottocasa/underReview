import Foundation

/// Did the author handle what the viewer asked? One verdict per request, after new commits or replies.
public struct FollowUpItem: Codable, Hashable, Sendable {
    public static let statuses = ["addressed", "partial", "not_addressed", "disputed", "unclear"]

    /// The thread the request was made in (as given in the prompt), or nil for the review summary.
    public var threadID: String?
    /// The request, in a few words.
    public var request: String
    /// addressed, partial, not_addressed, disputed (the author argued against it) or unclear.
    public var status: String
    /// Why, with the evidence: the change that handles it, or what's still missing.
    public var explanation: String

    public init(threadID: String?, request: String, status: String, explanation: String) {
        (self.threadID, self.request, self.status, self.explanation) = (threadID, request, status, explanation)
    }
}

public struct FollowUpResult: Codable, Hashable, Sendable {
    public var summary: String
    public var items: [FollowUpItem]
}

/// A stored follow-up check: like an AI review, it belongs to the head it ran on.
public struct FollowUpRun: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var prID: String
    public var engine: AIEngine
    public var headRefOid: String
    /// The commit the "changes since your review" started from; nil when the whole PR diff was used.
    public var reviewedOid: String?
    public var date = Date()
    public var result: FollowUpResult

    public init(prID: String, engine: AIEngine, headRefOid: String, reviewedOid: String?, result: FollowUpResult) {
        (self.prID, self.engine, self.headRefOid, self.reviewedOid, self.result) = (prID, engine, headRefOid, reviewedOid, result)
    }
}

public enum FollowUp {
    /// The viewer's open requests: unresolved threads they commented in.
    public static func threads(of viewer: String, in detail: PRDetail) -> [ReviewThread] {
        detail.threads.filter { thread in !thread.isResolved && thread.comments.contains { $0.author == viewer && !$0.isPending } }
    }

    /// Unresolved threads of the viewer where someone else wrote last: replies to look at.
    public static func replies(to viewer: String, in detail: PRDetail) -> Int {
        threads(of: viewer, in: detail).filter { $0.comments.last.map { $0.author != viewer } == true }.count
    }

    /// Worth a check: the viewer has open requests, and the author pushed since their review or replied.
    public static func isDue(_ pr: PullRequest, detail: PRDetail?, viewer: String) -> Bool {
        guard let detail else { return false }
        let hasRequests = !threads(of: viewer, in: detail).isEmpty || !reviewBodies(of: viewer, in: detail).isEmpty
        return hasRequests && (pr.needsReReview || replies(to: viewer, in: detail) > 0)
    }

    /// The threads *Resolve All Addressed* would resolve: judged addressed, still open and resolvable by the viewer,
    /// each once, in the run's order. None when the run is older than `head`, so a stale verdict resolves nothing.
    public static func resolvable(_ run: FollowUpRun, in detail: PRDetail, head: String) -> [ReviewThread] {
        guard run.headRefOid == head else { return [] }
        var seen = Set<String>()
        return run.result.items.compactMap { item in
            guard item.status == "addressed", let id = item.threadID, seen.insert(id).inserted else { return nil }
            return detail.threads.first { $0.id == id && !$0.isResolved && $0.viewerCanResolve }
        }
    }

    /// The run's items with those whose conversation is resolved moved to the end, each group in the run's order.
    public static func unresolvedFirst(_ items: [FollowUpItem], in detail: PRDetail?) -> [FollowUpItem] {
        let resolved = Set(detail?.threads.filter(\.isResolved).map(\.id) ?? [])
        let isResolved = { (item: FollowUpItem) in item.threadID.map(resolved.contains) ?? false }
        return items.filter { !isResolved($0) } + items.filter(isResolved)
    }

    /// The viewer's submitted review summaries, which can hold requests too.
    public static func reviewBodies(of viewer: String, in detail: PRDetail) -> [String] {
        detail.reviews.filter { $0.author == viewer && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.body)
    }

    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["summary","items"],"properties":{
      "summary":{"type":"string"},
      "items":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["threadID","request","status","explanation"],"properties":{
          "threadID":{"type":["string","null"]},
          "request":{"type":"string"},
          "status":{"type":"string","enum":["addressed","partial","not_addressed","disputed","unclear"]},
          "explanation":{"type":"string"}}}}}}
    """

    /// Editable in Settings. The schema and the material are always appended.
    public static let defaultInstructions = """
    You are helping a reviewer follow up on a GitHub pull request they already reviewed. Below are their open
    requests (inline threads with the replies since, and their review summary) and the code changes made since their
    review. For each request, decide whether the changes and replies handle it: `addressed`, `partial`,
    `not_addressed`, `disputed` (the author argued against it instead of changing the code) or `unclear`. In
    `explanation`, give the evidence in one to three sentences: the change that handles it (file and lines), what is
    still missing, or the reply's argument and whether it holds. Judge the substance, not the wording. Use only the
    material below; do not run tools or commands. Set `threadID` to the thread's id exactly as given, or null for a
    request from the review summary. `summary` says in one or two sentences what's left to do.
    """

    public static func prompt(title: String, viewer: String, threads: [ReviewThread], reviewBodies: [String],
                              changes: ReviewContext, sinceReview: Bool, instructions: String = defaultInstructions) -> String {
        var text = """
        \(instructions)
        Reply only with JSON matching this schema:
        \(schema)

        # \(title)

        The reviewer is **\(viewer)**.

        ## The reviewer's open threads

        """
        for thread in threads {
            text += "\n### Thread \(thread.id): \(thread.path)\(thread.line.map { ", line \($0)" } ?? "")\(thread.isOutdated ? " (the code it pointed at has changed)" : "")\n"
            for comment in thread.comments { text += "\n**\(comment.author)**:\n\(comment.body)\n" }
        }
        if !reviewBodies.isEmpty {
            text += "\n## The reviewer's review summary\n\n" + reviewBodies.joined(separator: "\n\n---\n\n") + "\n"
        }
        text += sinceReview
            ? "\n## Changes since the reviewer's review\n"
            : "\n## The pull request's whole diff\n\nWhat changed since the reviewer's review isn't available (no submitted review, or its commit was rewritten), so this is the full diff.\n"
        for file in changes.files where file.included {
            text += "\n### \(file.path)\n```diff\n\(file.patch ?? "")\n```\n"
        }
        let skipped = changes.files.filter { !$0.included }.map(\.path)
        if !skipped.isEmpty { text += "\nThese changed files' diffs were not provided: \(skipped.joined(separator: ", ")).\n" }
        if changes.files.isEmpty { text += "\nNo code changed.\n" }
        return text
    }
}
