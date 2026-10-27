import Foundation

/// What reviewers left on the viewer's own pull request that still needs an answer: open review threads and the
/// summaries of reviews that asked for changes or commented.
public struct FixPlanFeedback: Hashable, Sendable {
    public var threads: [ReviewThread]
    public var reviews: [Review]

    public init(threads: [ReviewThread], reviews: [Review]) {
        (self.threads, self.reviews) = (threads, reviews)
    }

    public var isEmpty: Bool { threads.isEmpty && reviews.isEmpty }
    public var count: Int { threads.count + reviews.count }

    /// Feedback id (thread or review) → what a new comment changes: the latest comment someone else wrote in the
    /// thread, or the review itself (a newer review from the same reviewer has a new id). The viewer's own replies
    /// don't count, so answering a comment doesn't make a plan outdated.
    public func markers(viewer: String) -> [String: String] {
        var markers: [String: String] = [:]
        for thread in threads {
            markers[thread.id] = thread.comments.last { $0.author != viewer && !$0.isPending }?.id ?? ""
        }
        for review in reviews { markers[review.id] = review.id }
        return markers
    }

    /// The files the threads point at, in order of first mention.
    public var paths: [String] {
        threads.map(\.path).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// Where an item's change goes: a file and, when the AI named them, NEW-side lines in its diff.
public struct FixPlanLocation: Codable, Hashable, Sendable {
    public var path: String
    public var startLine: Int?
    public var endLine: Int?

    public init(path: String, startLine: Int? = nil, endLine: Int? = nil) {
        (self.path, self.startLine, self.endLine) = (path, startLine, endLine)
    }

    /// "a.py:12–14", "a.py:12" or "a.py".
    public var label: String {
        guard let start = startLine else { return path }
        return endLine.map { $0 != start ? "\(path):\(start)–\($0)" : "\(path):\(start)" } ?? "\(path):\(start)"
    }
}

/// The plan for one piece of feedback: what to do about it, where, and what to answer the reviewer.
public struct FixPlanItem: Codable, Hashable, Sendable {
    public static let actions = ["change_code", "reply_only", "push_back", "already_done", "unclear"]
    public static let confidences = ["high", "medium", "low"]

    /// The thread or review the feedback came from, as given in the prompt.
    public var sourceID: String
    /// The request, in a few words.
    public var request: String
    /// change_code, reply_only, push_back (argue against it), already_done or unclear.
    public var action: String
    public var locations: [FixPlanLocation]
    /// What to change, in order; empty when there is nothing to change.
    public var steps: [String]
    /// The answer to post to the reviewer, in Markdown.
    public var reply: String
    /// high, medium or low.
    public var confidence: String

    public init(sourceID: String, request: String, action: String, locations: [FixPlanLocation] = [], steps: [String] = [],
                reply: String = "", confidence: String = "medium") {
        (self.sourceID, self.request, self.action, self.locations, self.steps, self.reply, self.confidence)
            = (sourceID, request, action, locations, steps, reply, confidence)
    }

    private enum CodingKeys: String, CodingKey { case sourceID, request, action, locations, steps, reply, confidence }

    /// Lenient, since Ollama only promises JSON, not the schema: missing fields get defaults, and an action or
    /// confidence outside the lists reads as unclear and low. Only a missing source fails.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        request = try container.decodeIfPresent(String.self, forKey: .request) ?? ""
        let action = try container.decodeIfPresent(String.self, forKey: .action) ?? ""
        self.action = Self.actions.contains(action) ? action : "unclear"
        locations = (try? container.decodeIfPresent([FixPlanLocation].self, forKey: .locations)) ?? []
        steps = (try? container.decodeIfPresent([String].self, forKey: .steps)) ?? []
        reply = try container.decodeIfPresent(String.self, forKey: .reply) ?? ""
        let confidence = try container.decodeIfPresent(String.self, forKey: .confidence) ?? ""
        self.confidence = Self.confidences.contains(confidence) ? confidence : "low"
    }
}

public struct FixPlanResult: Codable, Hashable, Sendable {
    public var summary: String
    public var items: [FixPlanItem]

    public init(summary: String, items: [FixPlanItem]) {
        (self.summary, self.items) = (summary, items)
    }

    private enum CodingKeys: String, CodingKey { case summary, items }

    /// Items that can't be read (no source) are dropped rather than failing the whole plan.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        items = try container.decode([Lenient<FixPlanItem>].self, forKey: .items).compactMap(\.value)
    }
}

/// Decodes `T`, or nil when that one element is malformed.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

/// A stored fix plan: like a follow-up check, it belongs to the head it ran on and to the feedback it saw.
public struct FixPlanRun: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var prID: String
    public var engine: AIEngine
    /// The model and effort it ran with (`AIOptions`, empty for the CLI's defaults).
    public var options: AIOptions?
    public var headRefOid: String
    public var date = Date()
    public var result: FixPlanResult
    /// The feedback the plan answered: `FixPlanFeedback.markers` at the time.
    public var feedback: [String: String]
    /// Only the diffs of the files the feedback points at were sent, since the whole diff was over the budget.
    public var partialDiff = false
    /// What the run used, when the CLI reported it.
    public var usage: TokenUsage?

    public init(prID: String, engine: AIEngine, headRefOid: String, feedback: [String: String], result: FixPlanResult) {
        (self.prID, self.engine, self.headRefOid, self.feedback, self.result) = (prID, engine, headRefOid, feedback, result)
    }
}

/// What the viewer decided about one item of a plan, stored locally per pull request and plan head.
public struct FixPlanChoice: Codable, Hashable, Sendable {
    public enum Decision: String, Codable, Sendable { case accepted, skipped }

    public var decision: Decision?
    /// The viewer's edits; nil keeps the plan's own.
    public var steps: [String]?
    public var reply: String?
    /// The head of the plan the choice was made on.
    public var head: String

    public init(head: String) { self.head = head }
}

public enum FixPlan {
    /// The feedback on the viewer's pull request still to address. Threads: unresolved, started by someone else, or
    /// started by the viewer with someone else writing last (the `threadsAwaitingReply` rule); outdated ones stay,
    /// since the comment may still apply. Reviews: each other reviewer's latest decision (an approval or change
    /// request wins over later comments, as in the sidebar counts); a change request's summary, or for a reviewer
    /// who only commented, their latest summary with text. Pending (unsubmitted) comments don't count.
    public static func feedback(in detail: PRDetail, viewer: String) -> FixPlanFeedback {
        let threads = detail.threads.filter { thread in
            let sent = thread.comments.filter { !$0.isPending }
            guard !thread.isResolved, let first = sent.first, let last = sent.last else { return false }
            return first.author != viewer || last.author != viewer
        }
        let hasText = { (review: Review) in !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let reviews = detail.latestReviews.filter { $0.author != viewer }.compactMap { latest -> Review? in
            switch latest.state {
            case "CHANGES_REQUESTED": return hasText(latest) ? latest : nil
            case "COMMENTED":
                // A reply in a thread is a COMMENTED review without text: the summary is in an earlier one.
                let comments = detail.reviews.enumerated().filter { $0.element.author == latest.author && $0.element.state == "COMMENTED" && hasText($0.element) }
                return comments.max { ($0.element.submittedAt ?? .distantPast, $0.offset) < ($1.element.submittedAt ?? .distantPast, $1.offset) }?.element
                    ?? (hasText(latest) ? latest : nil)
            default: return nil
            }
        }
        return FixPlanFeedback(threads: threads, reviews: reviews)
    }

    /// The diffs to send: the whole PR's when they fit the budget, otherwise only the files the feedback points at,
    /// fitted to the budget (the rest are named in the prompt). `partial` says which.
    public static func changes(pr: PullRequest, body: String, files: [FileChange], feedback: FixPlanFeedback,
                               budget: Int) -> (context: ReviewContext, partial: Bool) {
        let whole = AIContext.build(pr: pr, body: body, files: files, contents: [:], budget: budget)
        if whole.fitsBudget { return (whole, false) }
        let touched = Set(feedback.paths)
        var context = whole
        for index in context.files.indices where !touched.contains(context.files[index].path) { context.files[index].included = false }
        return (context.fittingBudget(), true)
    }

    /// Why `run` no longer matches the pull request, or nil when it's current: the head moved past the commit it
    /// planned on, or feedback is new or has new comments by someone else since. Feedback resolved since doesn't count.
    public static func outdatedReason(_ run: FixPlanRun, pr: PullRequest, feedback: FixPlanFeedback?, viewer: String) -> String? {
        let pushed = !pr.headRefOid.isEmpty && run.headRefOid != pr.headRefOid
        let commented = feedback.map { $0.markers(viewer: viewer).contains { run.feedback[$0.key] != $0.value } } ?? false
        let reasons = [pushed ? "New commits since this plan" : nil, commented ? "New feedback since this plan" : nil].compactMap { $0 }
        return reasons.isEmpty ? nil : reasons.joined(separator: " · ")
    }

    /// The plan with every line number the file's diff doesn't show dropped (the location keeps its file), as Suggest
    /// Fix refuses them: Changes could only open such a line approximately, and it may not exist at all.
    public static func validated(_ result: FixPlanResult, files: [FileChange]) -> FixPlanResult {
        let lines = Dictionary(files.map { file in
            (file.filename, Set(Diff.parse(file.patch ?? "").compactMap { $0.kind == .removed ? nil : $0.newLine }))
        }, uniquingKeysWith: { a, _ in a })
        var result = result
        for item in result.items.indices {
            for index in result.items[item].locations.indices {
                var location = result.items[item].locations[index]
                let known = lines[location.path] ?? []
                if location.endLine == nil { location.endLine = location.startLine }
                if location.startLine == nil { location.startLine = location.endLine }
                if let start = location.startLine, let end = location.endLine, !(known.contains(start) && known.contains(end) && start <= end) {
                    (location.startLine, location.endLine) = (nil, nil)
                }
                result.items[item].locations[index] = location
            }
        }
        return result
    }

    /// Items in the order the tab shows them: those about a review thread by file and line, then the rest (review
    /// summaries, or a source no longer on the pull request) in the plan's order. `threads` are all the PR's threads.
    public static func ordered(_ items: [FixPlanItem], threads: [ReviewThread]) -> [FixPlanItem] {
        let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let inline = items.enumerated().filter { byID[$0.element.sourceID] != nil }.sorted { a, b in
            let (x, y) = (byID[a.element.sourceID]!, byID[b.element.sourceID]!)
            return (x.path, x.line ?? 0, a.offset) < (y.path, y.line ?? 0, b.offset)
        }
        return inline.map(\.element) + items.filter { byID[$0.sourceID] == nil }
    }

    /// One PR's choices (item key → choice) after `change` to `key` at the plan head `head`. Choices made on another
    /// head are dropped, like Focus read marks: a new plan starts fresh.
    public static func choices(_ choices: [String: FixPlanChoice], setting key: String, head: String,
                               _ change: (inout FixPlanChoice) -> Void) -> [String: FixPlanChoice] {
        var choices = choices.filter { $0.value.head == head }
        var choice = choices[key] ?? FixPlanChoice(head: head)
        change(&choice)
        choices[key] = choice
        return choices
    }

    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["summary","items"],"properties":{
      "summary":{"type":"string"},
      "items":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["sourceID","request","action","locations","steps","reply","confidence"],"properties":{
          "sourceID":{"type":"string"},
          "request":{"type":"string"},
          "action":{"type":"string","enum":["change_code","reply_only","push_back","already_done","unclear"]},
          "locations":{"type":"array","items":{"type":"object","additionalProperties":false,
            "required":["path","startLine","endLine"],"properties":{
              "path":{"type":"string"},
              "startLine":{"type":["integer","null"]},
              "endLine":{"type":["integer","null"]}}}},
          "steps":{"type":"array","items":{"type":"string"}},
          "reply":{"type":"string"},
          "confidence":{"type":"string","enum":["high","medium","low"]}}}}}}
    """

    /// Editable in Settings. The schema and the material are always appended.
    public static let defaultInstructions = """
    You are helping the author of a GitHub pull request address the feedback reviewers left on it. Below are the open
    review threads (with every reply) and the reviews' summaries, then the code. Return exactly one item per thread
    and per review summary, with `sourceID` set to its id exactly as given. Pick the `action`: `change_code` when the
    code should change, `reply_only` when a question or remark only needs an answer, `push_back` when the request is
    wrong or not worth doing (say why, politely, in the reply), `already_done` when the code below already handles
    it, or `unclear`. For `change_code`, list the concrete `steps` in order and the `locations` to change: files and
    NEW-side line numbers shown in the diff below (null lines for a whole file or lines not shown). `reply` is what
    the author would post in answer, in Markdown, short and specific. `confidence` is high, medium or low. Use only
    the material below; do not run tools or commands. `summary` says in one or two sentences what the plan amounts to.
    """

    public static func prompt(title: String, body: String, author: String, feedback: FixPlanFeedback, changes: ReviewContext,
                              partial: Bool, instructions: String = defaultInstructions) -> String {
        var text = """
        \(instructions)
        Reply only with JSON matching this schema:
        \(schema)

        # \(title)

        \(body)

        The author is **\(author)**.

        """
        if !feedback.threads.isEmpty { text += "\n## Open review threads\n" }
        for thread in feedback.threads {
            text += "\n### Thread \(thread.id): \(thread.path)\(thread.line.map { ", line \($0)" } ?? "")\(thread.isOutdated ? " (outdated: the code it pointed at has changed since)" : "")\n"
            for comment in thread.comments where !comment.isPending { text += "\n**\(comment.author)**:\n\(comment.body)\n" }
        }
        if !feedback.reviews.isEmpty { text += "\n## Review summaries\n" }
        for review in feedback.reviews {
            let state = review.state == "CHANGES_REQUESTED" ? "requested changes" : "commented"
            text += "\n### Review \(review.id): \(review.author) \(state)\n\n\(review.body)\n"
        }
        text += partial
            ? "\n## Diff of the files the threads point at\n\nThe whole diff is over the budget, so only these files are shown.\n"
            : "\n## The pull request's diff\n"
        text += "\nEach line starts with its NEW-side number (none for removed lines), then +, - or a space as in the diff.\n"
        for file in changes.files where file.included {
            text += "\n### \(file.path)\n" + AIContext.fenced(AIContext.numbered(patch: file.patch ?? ""), info: "") + "\n"
        }
        let skipped = changes.files.filter { !$0.included }.map(\.path)
        if !skipped.isEmpty { text += "\nThese changed files' diffs were not provided: \(skipped.joined(separator: ", ")).\n" }
        if changes.files.isEmpty { text += "\nNo code changed.\n" }
        return text
    }
}
