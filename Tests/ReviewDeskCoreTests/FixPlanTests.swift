import Foundation
import Testing
@testable import ReviewDeskCore

private func comment(_ id: String, _ author: String, _ body: String, pending: Bool = false) -> ReviewDeskCore.Comment {
    ReviewDeskCore.Comment(id: id, author: author, body: body, createdAt: .now, isPending: pending, kind: .review)
}

private func thread(_ id: String, _ path: String, line: Int?, resolved: Bool = false, outdated: Bool = false,
                    _ comments: [ReviewDeskCore.Comment]) -> ReviewThread {
    ReviewThread(id: id, path: path, line: line, side: .right, isResolved: resolved, isOutdated: outdated, comments: comments)
}

private func review(_ id: String, _ author: String, _ state: String, _ body: String, at seconds: TimeInterval = 0) -> Review {
    Review(id: id, author: author, state: state, body: body, submittedAt: Date(timeIntervalSince1970: seconds))
}

// The viewer ("me") is the author of the pull request.
private let asked = thread("T1", "b.py", line: 9, outdated: true, [comment("C1", "bob", "Scope this query."), comment("C2", "me", "Will do.")])
private let answered = thread("T2", "a.py", line: 4, [comment("C3", "me", "Note to reviewers: see #12."), comment("C4", "eve", "Why not cache it?")])
private let myNote = thread("T3", "a.py", line: 7, [comment("C5", "me", "Heads-up: temporary.")])
private let done = thread("T4", "c.py", line: 1, resolved: true, [comment("C6", "bob", "Typo")])
private let draftOnly = thread("T5", "c.py", line: 3, [comment("C7", "me", "Self-note"), comment("C8", "me", "pending", pending: true)])

private let detail: PRDetail = {
    var detail = PRDetail(body: "Adds invites.", comments: [], reviews: [
        review("R1", "bob", "COMMENTED", "Looks close; see the query.", at: 1),
        review("R2", "bob", "CHANGES_REQUESTED", "Please scope the query and add a test.", at: 2),
        review("R3", "bob", "COMMENTED", "", at: 3),                          // a reply in a thread
        review("R4", "eve", "COMMENTED", "General: name the flag better.", at: 4),
        review("R5", "eve", "COMMENTED", "", at: 5),                           // eve's latest is a thread reply
        review("R6", "zoe", "APPROVED", "LGTM, one nit.", at: 6),
        review("R7", "me", "COMMENTED", "Answering everyone.", at: 7),
    ], threads: [asked, answered, myNote, done, draftOnly], pendingReview: nil)
    detail.latestReviews = [review("R2", "bob", "CHANGES_REQUESTED", "Please scope the query and add a test.", at: 2),
                            review("R5", "eve", "COMMENTED", "", at: 5), review("R6", "zoe", "APPROVED", "LGTM, one nit.", at: 6),
                            review("R7", "me", "COMMENTED", "Answering everyone.", at: 7)]
    return detail
}()

private func pr(head: String = "h1") -> PullRequest {
    var pr = PullRequest(id: "PR_1", number: 1, title: "Invites", url: "", state: "OPEN", isDraft: false, updatedAt: .now, headRefOid: head,
                         headRefName: "", baseRefName: "", author: "me", repo: "o/r", commentCount: 0, reviewCount: 1,
                         threadCommentCount: 0, requestedReviewers: [], stack: nil)
    pr.viewerIsAuthor = true
    return pr
}

@Test func fixPlanFeedbackIsOthersOpenThreadsAndTheirLatestReviews() {
    let feedback = FixPlan.feedback(in: detail, viewer: "me")
    // Resolved threads, the viewer's own unanswered ones and one with only a pending reply are out; outdated stays.
    #expect(feedback.threads.map(\.id) == ["T1", "T2"])
    // bob's change request wins over his later reply; eve's text is in her earlier comment; zoe approved; mine are out.
    #expect(feedback.reviews.map(\.id) == ["R2", "R4"])
    #expect(feedback.paths == ["b.py", "a.py"] && feedback.count == 4)
    // A reply of mine doesn't move the marker: only someone else's new comment does.
    #expect(feedback.markers(viewer: "me") == ["T1": "C1", "T2": "C4", "R2": "R2", "R4": "R4"])
    let empty = PRDetail(body: "", comments: [], reviews: [], threads: [myNote, done], pendingReview: nil)
    #expect(FixPlan.feedback(in: empty, viewer: "me").isEmpty)
}

@Test func fixPlanPromptCarriesTheFeedbackAndNumberedDiffs() {
    let feedback = FixPlan.feedback(in: detail, viewer: "me")
    let files = [FileChange(filename: "a.py", status: "modified", additions: 1, deletions: 0, patch: "@@ -1,1 +1,2 @@\n x\n+y"),
                 FileChange(filename: "b.py", status: "modified", additions: 1, deletions: 0, patch: "@@ -8,1 +8,2 @@\n q\n+scoped"),
                 FileChange(filename: "z.py", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1 @@\n+" + String(repeating: "z", count: 4000))]
    let whole = FixPlan.changes(pr: pr(), body: detail.body, files: files, feedback: feedback, budget: 10_000)
    #expect(!whole.partial && whole.context.files.allSatisfy(\.included))
    // Over the budget: only the files the threads point at.
    let partial = FixPlan.changes(pr: pr(), body: detail.body, files: files, feedback: feedback, budget: 500)
    #expect(partial.partial && partial.context.files.filter(\.included).map(\.path) == ["a.py", "b.py"])

    let text = FixPlan.prompt(title: "Invites", body: detail.body, author: "me", feedback: feedback, changes: partial.context, partial: true)
    #expect(text.hasPrefix(FixPlan.defaultInstructions) && text.contains(FixPlan.schema))
    #expect(text.contains("### Thread T1: b.py, line 9 (outdated"))
    #expect(text.contains("**bob**:\nScope this query.") && text.contains("**me**:\nWill do."))
    #expect(text.contains("### Review R2: bob requested changes\n\nPlease scope the query and add a test."))
    #expect(text.contains("### Review R4: eve commented"))
    #expect(text.contains("    9 +scoped"))
    #expect(text.contains("only these files are shown") && text.contains("were not provided: z.py"))
    // A custom prompt replaces the instructions only; the result format stays.
    let custom = FixPlan.prompt(title: "Invites", body: "", author: "me", feedback: feedback, changes: whole.context, partial: false, instructions: "Be brief.")
    #expect(custom.hasPrefix("Be brief.\nReply only with JSON matching this schema:\n\(FixPlan.schema)"))
    #expect(!custom.contains("were not provided"))
}

@Test func fixPlanResultsParseLeniently() throws {
    let valid = #"{"summary":"Two changes.","items":[{"sourceID":"T1","request":"Scope the query","action":"change_code","locations":[{"path":"b.py","startLine":9,"endLine":9}],"steps":["Filter by org"],"reply":"Done.","confidence":"high"}]}"#
    let result = try JSONDecoder().decode(FixPlanResult.self, from: Data(valid.utf8))
    #expect(result.items == [FixPlanItem(sourceID: "T1", request: "Scope the query", action: "change_code",
                                         locations: [FixPlanLocation(path: "b.py", startLine: 9, endLine: 9)],
                                         steps: ["Filter by org"], reply: "Done.", confidence: "high")])
    let schema = try #require(try JSONSerialization.jsonObject(with: Data(FixPlan.schema.utf8)) as? [String: Any])
    #expect(schema["required"] as? [String] == ["summary", "items"])

    // Partial: missing fields get defaults, unknown values read as unclear / low, an item without a source is dropped.
    let partial = #"{"items":[{"sourceID":"T2","action":"rewrite_everything","confidence":"total"},{"request":"no source"},{"sourceID":"R2","locations":"b.py"}]}"#
    let lenient = try JSONDecoder().decode(FixPlanResult.self, from: Data(partial.utf8))
    #expect(lenient.summary == "" && lenient.items.map(\.sourceID) == ["T2", "R2"])
    #expect(lenient.items[0].action == "unclear" && lenient.items[0].confidence == "low" && lenient.items[0].steps.isEmpty)
    #expect(lenient.items[1].locations.isEmpty)

    for malformed in ["not json", #"{"summary":"no items"}"#, #"{"items":{"sourceID":"T1"}}"#] {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(FixPlanResult.self, from: Data(malformed.utf8)) }
    }
}

@Test func fixPlanDropsLinesOutsideTheDiff() {
    let files = [FileChange(filename: "a.py", status: "modified", additions: 2, deletions: 1, patch: "@@ -10,2 +10,3 @@\n x\n-old\n+new\n+more")]
    func location(_ path: String, _ start: Int?, _ end: Int?) -> FixPlanLocation { FixPlanLocation(path: path, startLine: start, endLine: end) }
    let item = FixPlanItem(sourceID: "T1", request: "", action: "change_code", locations: [
        location("a.py", 10, 12), location("a.py", 11, nil), location("a.py", 9, 10), location("a.py", 12, 10),
        location("a.py", 1_000_000_000, 1_000_000_000), location("other.py", 3, 4), location("a.py", nil, nil),
    ])
    let checked = FixPlan.validated(FixPlanResult(summary: "", items: [item]), files: files).items[0].locations
    #expect(checked == [location("a.py", 10, 12), location("a.py", 11, 11), location("a.py", nil, nil), location("a.py", nil, nil),
                        location("a.py", nil, nil), location("other.py", nil, nil), location("a.py", nil, nil)])
    #expect(checked[0].label == "a.py:10–12" && checked[1].label == "a.py:11" && checked[2].label == "a.py")
}

@Test func aFixPlanIsOutdatedAfterAPushOrNewFeedback() {
    let feedback = FixPlan.feedback(in: detail, viewer: "me")
    let run = FixPlanRun(prID: "PR_1", engine: .claudeCode, headRefOid: "h1", feedback: feedback.markers(viewer: "me"),
                         result: FixPlanResult(summary: "", items: []))
    #expect(FixPlan.outdatedReason(run, pr: pr(), feedback: feedback, viewer: "me") == nil)
    #expect(FixPlan.outdatedReason(run, pr: pr(head: "h2"), feedback: feedback, viewer: "me") == "New commits since this plan")
    #expect(FixPlan.outdatedReason(run, pr: pr(head: ""), feedback: feedback, viewer: "me") == nil) // an unknown head isn't a push

    var replied = feedback, commented = feedback, resolved = feedback
    replied.threads[0].comments.append(comment("C9", "me", "Pushed the fix."))  // the viewer's own reply
    commented.threads[0].comments.append(comment("C9", "bob", "Also the other query."))
    resolved.threads.removeFirst()
    #expect(FixPlan.outdatedReason(run, pr: pr(), feedback: replied, viewer: "me") == nil)
    #expect(FixPlan.outdatedReason(run, pr: pr(), feedback: resolved, viewer: "me") == nil)
    #expect(FixPlan.outdatedReason(run, pr: pr(head: "h2"), feedback: commented, viewer: "me")
            == "New commits since this plan · New feedback since this plan")
    var newReview = feedback
    newReview.reviews.append(review("R8", "kai", "COMMENTED", "One more thing."))
    #expect(FixPlan.outdatedReason(run, pr: pr(), feedback: newReview, viewer: "me") == "New feedback since this plan")
    #expect(FixPlan.outdatedReason(run, pr: pr(), feedback: nil, viewer: "me") == nil) // detail not loaded yet
}

@Test func fixPlanItemsAreShownInFileOrderThenGeneralRemarks() {
    func item(_ source: String) -> FixPlanItem { FixPlanItem(sourceID: source, request: "", action: "reply_only") }
    let items = [item("R2"), item("T1"), item("T9"), item("T4"), item("T2")]
    // a.py:4 (T2), b.py:9 (T1), c.py:1 (T4, resolved since but still a thread), then R2 and the unknown T9 in plan order.
    #expect(FixPlan.ordered(items, threads: detail.threads).map(\.sourceID) == ["T2", "T1", "T4", "R2", "T9"])
}

@Test func fixPlanTallyCountsEachAction() {
    func item(_ action: String) -> FixPlanItem { FixPlanItem(sourceID: "T1", request: "", action: action) }
    #expect(FixPlan.tally([item("change_code"), item("change_code"), item("already_done")])
            == "2 to change · 0 reply only · 0 push back · 1 already done")
    #expect(FixPlan.tally([item("unclear")]).hasSuffix(" · 1 unclear"))
}

@Test func fixPlanChoicesBelongToThePlansHead() {
    var choices = FixPlan.choices([:], setting: "T1", head: "h1") { $0.decision = .accepted }
    choices = FixPlan.choices(choices, setting: "T1", head: "h1") { $0.reply = "Thanks, done." }
    choices = FixPlan.choices(choices, setting: "T2", head: "h1") { $0.decision = .skipped }
    #expect(choices["T1"]?.decision == .accepted && choices["T1"]?.reply == "Thanks, done." && choices["T2"]?.decision == .skipped)
    // A plan on a new head starts fresh: the old head's choices are dropped.
    let next = FixPlan.choices(choices, setting: "T2", head: "h2") { $0.steps = ["Rename it"] }
    #expect(next.keys.sorted() == ["T2"] && next["T2"]?.decision == nil && next["T2"]?.steps == ["Rename it"])
}
