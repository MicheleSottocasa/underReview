import Foundation

/// What reviewers left on the viewer's own pull request that still needs an answer: open review threads, the
/// summaries of reviews that asked for changes or commented, and the findings of ReviewDesk's own AI review.
public struct FixPlanFeedback: Hashable, Sendable {
    public var threads: [ReviewThread]
    public var reviews: [Review]
    public var findings: [FixPlanAIFinding]

    public init(threads: [ReviewThread], reviews: [Review], findings: [FixPlanAIFinding] = []) {
        (self.threads, self.reviews, self.findings) = (threads, reviews, findings)
    }

    public var isEmpty: Bool { threads.isEmpty && reviews.isEmpty && findings.isEmpty }
    public var count: Int { threads.count + reviews.count + findings.count }

    /// Feedback id (thread or review) → what a new comment changes: the latest comment someone else wrote in the
    /// thread, or the review itself (a newer review from the same reviewer has a new id). The viewer's own replies
    /// don't count, so answering a comment doesn't make a plan outdated.
    public func markers(viewer: String) -> [String: String] {
        var markers: [String: String] = [:]
        for thread in threads {
            markers[thread.id] = thread.comments.last { $0.author != viewer && !$0.isPending }?.id ?? ""
        }
        for review in reviews { markers[review.id] = review.id }
        for finding in findings { markers[finding.id] = finding.id }
        return markers
    }

    /// The files the threads and findings point at, in order of first mention.
    public var paths: [String] {
        (threads.map(\.path) + findings.compactMap(\.finding.path)).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// A finding of an AI review run on the pull request (`AIRun`), whether it's only shown in AI Review or was added to
/// the pending review: the author addresses it like a reviewer's comment.
public struct FixPlanAIFinding: Hashable, Sendable {
    /// `ai:<run id>:<finding index>`, the plan item's `sourceID`.
    public var id: String
    public var finding: Finding
    /// Who reviewed: the engine's name, e.g. "Claude Code".
    public var reviewer: String
    /// The commit the review ran on.
    public var head: String

    public init(id: String, finding: Finding, reviewer: String, head: String) {
        (self.id, self.finding, self.reviewer, self.head) = (id, finding, reviewer, head)
    }

    /// "a.py:12" or "a.py", or nil for a general remark.
    public var location: String? { finding.path.map { path in finding.line.map { "\(path):\($0)" } ?? path } }

    /// Every finding of `run`, dismissed or not: what a stored plan's items point back at.
    public static func all(in run: AIRun) -> [FixPlanAIFinding] {
        run.result.findings.enumerated().map {
            FixPlanAIFinding(id: "ai:\(run.id.uuidString):\($0.offset)", finding: $0.element, reviewer: run.engine.name, head: run.headRefOid)
        }
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
    /// The reply went to GitHub from the plan. Nil in choices saved before replies could be posted.
    public var posted: Bool?

    public init(head: String) { self.head = head }
}

extension FixPlanItem {
    /// The item with the viewer's edits to its steps and reply, when they made some.
    public func applying(_ choice: FixPlanChoice?) -> FixPlanItem {
        var item = self
        if let steps = choice?.steps { item.steps = steps }
        if let reply = choice?.reply { item.reply = reply }
        return item
    }
}

/// A proposed reply ready to post: in its review thread, or as a pull request comment for a review's summary.
public struct FixPlanReply: Hashable, Sendable {
    /// The plan item, i.e. its feedback id.
    public var sourceID: String
    /// The thread to reply in; nil posts `body` as a comment on the pull request.
    public var threadID: String?
    public var body: String
    /// Where it goes, for the confirmation: "a.py:12" or "alice's review".
    public var label: String
}

public enum FixPlan {
    /// How many of the pull request's latest commits an AI review may have run on for its findings to be planned.
    public static let recentCommits = 3

    /// The findings of the newest AI review run on one of the pull request's last `recentCommits` commits (`commits`
    /// oldest first, as `PRDetail` lists them), but the dismissed ones. Findings added to the pending review stay:
    /// they still need addressing in the code.
    public static func aiFindings(_ runs: [AIRun], prID: String, commits: [String]) -> [FixPlanAIFinding] {
        let recent = Set(commits.suffix(recentCommits))
        guard let run = runs.filter({ $0.prID == prID && recent.contains($0.headRefOid) }).max(by: { $0.date < $1.date }) else { return [] }
        let dismissed = run.dismissed ?? []
        return FixPlanAIFinding.all(in: run).enumerated().filter { !dismissed.contains($0.offset) }.map(\.element)
    }

    /// The feedback on the viewer's pull request still to address. Threads: unresolved, started by someone else, or
    /// started by the viewer with someone else writing last (the `threadsAwaitingReply` rule); outdated ones stay,
    /// since the comment may still apply. Reviews: each other reviewer's latest decision (an approval or change
    /// request wins over later comments, as in the sidebar counts); a change request's summary, or for a reviewer
    /// who only commented, their latest summary with text. Pending (unsubmitted) comments don't count.
    /// `findings` are the AI review's to add (`aiFindings`).
    public static func feedback(in detail: PRDetail, viewer: String, findings: [FixPlanAIFinding] = []) -> FixPlanFeedback {
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
        return FixPlanFeedback(threads: threads, reviews: reviews, findings: findings)
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
    /// planned on, or feedback is new or has new comments by someone else since. Feedback resolved since doesn't count,
    /// and once none is left there's nothing to plan again, so a later push doesn't make the plan outdated either.
    public static func outdatedReason(_ run: FixPlanRun, pr: PullRequest, feedback: FixPlanFeedback?, viewer: String) -> String? {
        if feedback?.isEmpty == true { return nil }
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

    /// Items in the order the tab shows them: those about a review thread or an AI finding on a file, by file and
    /// line, then the rest (review summaries, general findings, or a source no longer there) in the plan's order.
    /// `threads` are all the PR's threads.
    public static func ordered(_ items: [FixPlanItem], threads: [ReviewThread], findings: [FixPlanAIFinding] = []) -> [FixPlanItem] {
        var places = Dictionary(threads.map { ($0.id, ($0.path, $0.line ?? 0)) }, uniquingKeysWith: { a, _ in a })
        for finding in findings {
            if let path = finding.finding.path { places[finding.id] = places[finding.id] ?? (path, finding.finding.line ?? 0) }
        }
        let inline = items.enumerated().filter { places[$0.element.sourceID] != nil }.sorted { a, b in
            let (x, y) = (places[a.element.sourceID]!, places[b.element.sourceID]!)
            return (x.0, x.1, a.offset) < (y.0, y.1, b.offset)
        }
        return inline.map(\.element) + items.filter { places[$0.sourceID] == nil }
    }

    /// The plan at a glance: "2 to change · 1 reply only · 0 push back · 1 already done", plus the unclear ones if any.
    public static func tally(_ items: [FixPlanItem]) -> String {
        let counts = Dictionary(grouping: items, by: \.action).mapValues(\.count)
        let parts = [("change_code", "to change"), ("reply_only", "reply only"), ("push_back", "push back"), ("already_done", "already done")]
            .map { "\(counts[$0.0] ?? 0) \($0.1)" }
        return (parts + (counts["unclear"].map { ["\($0) unclear"] } ?? [])).joined(separator: " · ")
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

    /// The reply to post for `item` (with the viewer's edits), or nil when there's none or its feedback is gone. A
    /// thread gets the reply as is; a review summary has no thread, so the reply quotes its first line. An AI finding
    /// has nobody to answer, so it gets none.
    public static func reply(_ item: FixPlanItem, threads: [ReviewThread], reviews: [Review]) -> FixPlanReply? {
        let body = item.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if let thread = threads.first(where: { $0.id == item.sourceID }) {
            return FixPlanReply(sourceID: item.sourceID, threadID: thread.id, body: body,
                                label: thread.line.map { "\(thread.path):\($0)" } ?? thread.path)
        }
        guard let review = reviews.first(where: { $0.id == item.sourceID }) else { return nil }
        let first = review.body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let quote = first.count > 200 ? String(first.prefix(200)) + "…" : first
        return FixPlanReply(sourceID: item.sourceID, threadID: nil, body: quote.isEmpty ? body : "> \(quote)\n\n\(body)",
                            label: "\(review.author)'s review")
    }

    /// The replies *Post Accepted Replies* sends: accepted items with a reply, not posted yet, in the tab's order.
    public static func acceptedReplies(_ items: [FixPlanItem], choices: [String: FixPlanChoice], threads: [ReviewThread],
                                       reviews: [Review]) -> [FixPlanReply] {
        ordered(items, threads: threads).compactMap { item in
            let choice = choices[item.sourceID]
            guard choice?.decision == .accepted, choice?.posted != true else { return nil }
            return reply(item.applying(choice), threads: threads, reviews: reviews)
        }
    }

    /// The accepted "change code" items as one prompt to paste into a coding agent in the local clone: the pull
    /// request, then each item with the reviewer's comment, where to change and the steps. It asks for the changes
    /// only: no commit, no push, no replies. `head` is the commit the plan's line numbers are from; `notes`, the
    /// author's own instructions, close the prompt when there are any.
    public static func agentPrompt(pr: PullRequest, head: String, items: [FixPlanItem], choices: [String: FixPlanChoice],
                                   threads: [ReviewThread], reviews: [Review], findings: [FixPlanAIFinding] = [],
                                   notes: String = "") -> String {
        let accepted = ordered(items, threads: threads, findings: findings).filter { choices[$0.sourceID]?.decision == .accepted && $0.action == "change_code" }
        var text = """
        Address review feedback on pull request \(pr.repo)#\(pr.number), "\(pr.title)" (branch \(pr.headRefName), \
        into \(pr.baseRefName)). You are in a local clone of the repository: check that \(pr.headRefName) is checked out \
        first. Make the code changes below and nothing else. Don't commit, push or reply to anyone. Line numbers are \
        from commit \(head.prefix(7)); find the code by its content if it moved.

        """
        for (index, item) in accepted.map({ $0.applying(choices[$0.sourceID]) }).enumerated() {
            text += "\n## \(index + 1). \(item.request)\n"
            if let thread = threads.first(where: { $0.id == item.sourceID }), let comment = thread.comments.first(where: { !$0.isPending }) {
                text += "\nReviewer comment by \(comment.author) on \(thread.path)\(thread.line.map { ":\($0)" } ?? ""):\n"
                text += comment.body.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n"
            } else if let review = reviews.first(where: { $0.id == item.sourceID }) {
                text += "\nFrom \(review.author)'s review:\n"
                text += review.body.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n"
            } else if let finding = findings.first(where: { $0.id == item.sourceID }) {
                text += "\nAI review finding (\(finding.finding.severity))\(finding.location.map { " on \($0)" } ?? ""):\n"
                text += finding.finding.comment.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n"
            }
            if !item.locations.isEmpty { text += "\nWhere: " + item.locations.map(\.label).joined(separator: ", ") + "\n" }
            if !item.steps.isEmpty {
                text += "\nSteps:\n" + item.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n"
            }
        }
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { text += "\n## Additional instructions from the author\n\n\(notes)\n" }
        return text
    }

    /// The shell line Fix types in a new Terminal window: the agent (`claude` or `codex`) in the clone, started on the
    /// prompt saved at `promptFile`, which it reads and deletes. A file, so review text never meets shell quoting.
    public static func agentCommand(tool: String, clone: String, promptFile: String) -> String {
        let file = Updater.shellQuoted(promptFile)
        return "cd \(Updater.shellQuoted(clone)) && \(tool) \"$(cat \(file); rm -f \(file))\""
    }

    /// Ids of the "change code" items of a plan made at an older head whose code changed since: `changes` are the
    /// files changed from the plan's head to the current one (GitHub's compare), so their OLD side is the code the plan
    /// read. A location with lines counts when a changed line falls in them, one without when its file changed.
    /// Only a hint: re-planning confirms.
    public static func maybeDone(_ items: [FixPlanItem], changes: [FileChange]) -> Set<String> {
        let touched = Dictionary(changes.map { ($0.filename, changedOldLines($0.patch ?? "")) }, uniquingKeysWith: { a, _ in a })
        return Set(items.filter { item in
            item.action == "change_code" && item.locations.contains { location in
                guard let lines = touched[location.path] else { return false }
                guard let start = location.startLine else { return true }
                return lines.contains { (start...max(start, location.endLine ?? start)).contains($0) }
            }
        }.map(\.sourceID))
    }

    /// The old-side lines a patch changes: the removed ones, and those on either side of an addition.
    static func changedOldLines(_ patch: String) -> Set<Int> {
        var lines: Set<Int> = [], previous: Int?, added = false
        for line in Diff.parse(patch) {
            switch line.kind {
            case .hunk: (previous, added) = (nil, false)
            case .added:
                if let previous { lines.formUnion([previous, previous + 1]) } else { added = true }
            case .removed, .context:
                if line.kind == .removed, let old = line.oldLine { lines.insert(old) }
                if added, let old = line.oldLine { lines.insert(old) }
                (previous, added) = (line.oldLine, false)
            }
        }
        return lines
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
    review threads (with every reply), the reviews' summaries and an AI review's findings, then the code. Return
    exactly one item per thread, per review summary and per finding, with `sourceID` set to its id exactly as given. Pick the `action`: `change_code` when the
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
        // Explained here, not in the editable instructions, so a custom prompt still plans the findings.
        if !feedback.findings.isEmpty {
            text += "\n## AI review findings\n\nAn automated review found these: plan one item each like a reviewer's comment, "
                + "judged on the code. Nobody waits for an answer, so leave `reply` empty.\n"
        }
        for finding in feedback.findings {
            let item = finding.finding
            text += "\n### Finding \(finding.id): \(finding.location ?? "general") (\(item.severity))\n\n**\(item.title)**\n\n\(item.rationale)\n"
            if item.comment != item.rationale, !item.comment.isEmpty { text += "\n\(item.comment)\n" }
            if let suggestion = item.suggestion, !suggestion.isEmpty { text += "\nProposed code:\n" + AIContext.fenced(suggestion, info: "") + "\n" }
        }
        text += partial
            ? "\n## Diff of the files the feedback points at\n\nThe whole diff is over the budget, so only these files are shown.\n"
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
