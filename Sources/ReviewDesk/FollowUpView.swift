import ReviewDeskCore
import SwiftUI

/// Under the PR header when the author pushed since your review or replied to your comments.
struct FollowUpNotice: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        let replies = model.details[pr.id].map { FollowUp.replies(to: model.viewer, in: $0) } ?? 0
        let parts = [pr.needsReReview ? "New commits since your review" : nil,
                     replies > 0 ? "\(replies) repl\(replies == 1 ? "y" : "ies") to your comments" : nil].compactMap { $0 }
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            Text(parts.joined(separator: " · ")).font(.callout)
            Spacer()
            let stackDue = model.stackMembers(of: pr).filter(model.isFollowUpDue)
            if stackDue.count > 1 {
                Button("Check Stack (\(stackDue.count))") {
                    model.detailTab = .followUp
                    model.startStackFollowUp(stackDue, from: pr.id)
                }
                .disabled(model.isAIBusy(pr))
                .help("Check every pull request of the stack with new commits or replies since your review, bottom first")
            }
            EstimateLabel(estimate: model.followUpEstimate(pr, engine: model.preferredEngine(for: pr)), prefix: "up to ",
                          help: "At most: assumes the whole diff, but only what changed since your review is sent. It counts toward your plan's limits.")
            Button("Check if Addressed") {
                model.detailTab = .followUp
                model.startFollowUp(pr)
            }
            .disabled(model.isAIBusy(pr))
            .help("Ask \(model.preferredEngine(for: pr).name) whether the changes and replies handle each of your comments")
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Did the author handle what you asked? One verdict per open request, from the changes and replies since your review.
struct FollowUpView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        let runs = model.followUpRuns(for: pr.id)
        let detail = model.details[pr.id]
        let threads = detail.map { FollowUp.threads(of: model.viewer, in: $0) } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Did the author handle your comments?").font(.title3.bold())
                        Text("Checks each of your open threads and your review summary against the replies and the code changed since your review.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    EstimateLabel(estimate: model.followUpEstimate(pr, engine: model.preferredEngine(for: pr)), prefix: "up to ",
                                  help: "At most: assumes the whole diff, but only what changed since your review is sent. It counts toward your plan's limits.")
                    Button(runs.isEmpty ? "Check Now" : "Check Again") { model.startFollowUp(pr) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isAIBusy(pr) || (threads.isEmpty && detail.map { FollowUp.reviewBodies(of: model.viewer, in: $0) }?.isEmpty != false))
                        .help("Uses \(model.preferredEngine(for: pr).name), the engine picked in the AI Review tab")
                }
                if let detail, ReviewEvent.allowed(for: pr).contains(.approve) {
                    ApproveFromFollowUp(pr: pr, blocker: FollowUp.approvalBlocker(pr, latest: runs.first, in: detail, viewer: model.viewer(for: pr)))
                }
                AIProgress(pr: pr)
                let members = model.stackMembers(of: pr)
                if members.count > 1 { StackFollowUp(pr: pr, members: members) }
                if let run = runs.first {
                    FollowUpRunView(pr: pr, run: run)
                } else if threads.isEmpty {
                    Text("You have no open review threads on this pull request.").foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await model.loadDetail(pr.id)
            // The stack card needs each member's threads to tell what's due.
            for member in model.stackMembers(of: pr) where model.details[member.id] == nil { await model.loadDetail(member.id) }
        }
    }
}

/// The follow-up state of every PR in the stack, and one button to check all that changed.
private struct StackFollowUp: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let members: [PullRequest]

    var body: some View {
        let due = members.filter(model.isFollowUpDue)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Stack #\(pr.stack?.number ?? 0)", systemImage: "square.stack.3d.up").font(.headline)
                let approved = model.stackPullRequests(of: pr).filter { $0.state == "OPEN" && $0.isApprovedByViewer }.count
                if approved > 0 {
                    Text("\(approved) approved by you, hidden").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                EstimateLabel(estimate: due.isEmpty ? nil : model.followUpEstimate(due, engine: model.preferredEngine(for: pr)), prefix: "up to ",
                              help: "At most: assumes the whole diff, but only what changed since your review is sent. It counts toward your plan's limits.")
                Button("Check Stack (\(due.count))") { model.startStackFollowUp(due, from: pr.id) }
                    .disabled(due.isEmpty || model.isAIBusy(pr))
                    .help(due.isEmpty ? "Nothing new since your review in this stack"
                                      : "Check the \(due.count) pull request\(due.count == 1 ? "" : "s") with new commits or replies since your review, bottom first")
            }
            ForEach(members) { member in
                let run = model.followUpRuns(for: member.id).first
                Button { model.selection = [.pr(member.id)] } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: "\(member.stackPosition ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                        Text(verbatim: "#\(member.number) \(member.title)").lineLimit(1).fontWeight(member.id == pr.id ? .semibold : .regular)
                        Spacer()
                        if let run {
                            let counts = Dictionary(grouping: run.result.items, by: \.status).mapValues(\.count)
                            ForEach(FollowUpItem.statuses, id: \.self) { status in
                                if let count = counts[status] { FollowUpBadge(status: status, count: count) }
                            }
                            if run.headRefOid != member.headRefOid { Badge(text: "Outdated", color: .orange) }
                        } else if model.isFollowUpDue(member) {
                            Badge(text: "New since your review", color: .orange)
                        } else {
                            Text("Nothing new").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open #\(member.number)'s follow-up")
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }
}

private struct FollowUpRunView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let run: FollowUpRun
    @ViewState private var showsResolved = false

    private func row(_ item: FollowUpItem) -> FollowUpItemView {
        FollowUpItemView(pr: pr, item: item, thread: item.threadID.flatMap { id in model.details[pr.id]?.threads.first { $0.id == id } })
    }

    var body: some View {
        let counts = Dictionary(grouping: run.result.items, by: \.status).mapValues(\.count)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").foregroundStyle(.purple)
                Text(run.engine.name).bold()
                Text(run.date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                UsageLabel(usage: run.usage)
                if run.headRefOid != pr.headRefOid { Badge(text: "New commits since this check", color: .orange) }
                if run.reviewedOid == nil { Badge(text: "Whole diff", color: .secondary).help("What changed since your review wasn't available") }
                Spacer()
                Button("Delete") { model.deleteFollowUp(run.id) }.buttonStyle(.link)
            }
            .font(.callout)
            HStack(spacing: 6) {
                ForEach(FollowUpItem.statuses, id: \.self) { status in
                    if let count = counts[status] { FollowUpBadge(status: status, count: count) }
                }
            }
            MarkdownText(run.result.summary)
            ResolveAllAddressed(pr: pr, run: run)
            let split = FollowUp.splitByResolution(run.result.items, in: model.details[pr.id])
            ForEach(Array(split.open.enumerated()), id: \.offset) { _, item in row(item) }
            // Resolved conversations sit in their own section, always last and collapsed until opened.
            if !split.resolved.isEmpty {
                DisclosureGroup(isExpanded: $showsResolved) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(split.resolved.enumerated()), id: \.offset) { _, item in row(item) }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Resolved (\(split.resolved.count))", systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout.bold())
                }
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.25)))
    }
}

/// One button for every addressed thread still open, after a confirmation that lists them.
/// ponytail: per pull request only; a stack-wide one needs a dialog listing threads across PRs.
private struct ResolveAllAddressed: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let run: FollowUpRun
    @ViewState private var confirming = false

    var body: some View {
        if let detail = model.details[pr.id] {
            // Counted as of the check's own head, so an outdated check still says what it would resolve.
            let threads = FollowUp.resolvable(run, in: detail, head: run.headRefOid)
            let outdated = run.headRefOid != pr.headRefOid
            let busy = threads.contains { model.pending.contains($0.id) }
            if !threads.isEmpty {
                HStack(spacing: 8) {
                    Button("Resolve All Addressed (\(threads.count))") { confirming = true }
                        .disabled(outdated || busy)
                        .help(outdated ? "This check ran before the latest commits: check again before resolving in bulk"
                                       : "Resolve the \(threads.count) conversation\(threads.count == 1 ? "" : "s") judged addressed")
                    if busy { ProgressView().controlSize(.small) }
                    if outdated { Text("Check again to resolve in bulk: new commits since this check.").font(.caption).foregroundStyle(.secondary) }
                }
                .controlSize(.small)
                .confirmationDialog("Resolve \(threads.count) conversation\(threads.count == 1 ? "" : "s")?", isPresented: $confirming) {
                    Button("Resolve \(threads.count)") {
                        // Re-picked against the latest head: a push since rendering resolves nothing.
                        let current = model.prs[pr.id]?.headRefOid ?? pr.headRefOid
                        Task { await model.resolveAll(FollowUp.resolvable(run, in: model.details[pr.id] ?? detail, head: current), pr: pr) }
                    }
                } message: {
                    Text(threads.map { thread in
                        let request = run.result.items.first { $0.threadID == thread.id }?.request ?? ""
                        return "• \(thread.path)\(thread.line.map { ":\($0)" } ?? ""): \(request)"
                    }.joined(separator: "\n"))
                }
            }
        }
    }
}

/// Approves once your threads are resolved and the latest check ran on the head; otherwise says what's missing.
/// Hidden on your own pull request, where GitHub refuses an approval.
private struct ApproveFromFollowUp: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let blocker: String?
    @ViewState private var confirming = false

    var body: some View {
        let busy = model.pending.contains("\(pr.id):approve")
        HStack(spacing: 8) {
            Button("Approve…") { confirming = true }
                .disabled(blocker != nil || busy)
                .help(blocker ?? "Submit an approving review, after a confirmation with an optional comment")
                .popover(isPresented: $confirming) { confirmation }
            if busy { ProgressView().controlSize(.small) }
            if let blocker { Text(blocker).font(.caption).foregroundStyle(.secondary) }
        }
        .controlSize(.small)
    }

    private var confirmation: some View {
        let unsaved = model.drafts(for: pr.id).filter(\.needsSync)
        let toSend = unsaved.filter { !$0.isStale }.count + (pr.pendingReviewComments ?? 0)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Approve #\(pr.number)?").font(.headline)
            CommentComposer(text: Binding(
                get: { model.reviewDrafts.bodies[pr.id] ?? "" },
                set: { model.reviewDrafts.bodies[pr.id] = $0.isEmpty ? nil : $0 }
            ), placeholder: "Leave a comment (optional)")
            // The same path as Submit Review: local drafts and the pending review go out with the approval.
            if unsaved.contains(where: \.isStale) {
                Label("Outdated drafts are left out until you confirm or delete them.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if toSend > 0 {
                Text("\(toSend) comment\(toSend == 1 ? "" : "s") not submitted yet will be submitted with the approval.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { confirming = false }.keyboardShortcut(.cancelAction)
                Button("Approve") {
                    confirming = false
                    Task { await model.whilePending("\(pr.id):approve") { await model.submitReview(pr, event: .approve) } }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

private struct FollowUpItemView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let item: FollowUpItem
    let thread: ReviewThread?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FollowUpBadge(status: item.status)
                Text(inlineMarkdown(item.request, repo: pr.repo)).bold()
                Spacer()
                Text(verbatim: thread.map { "\($0.path)\($0.line.map { ":\($0)" } ?? "")" } ?? "Review summary")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            MarkdownText(item.explanation).font(.callout)
            if let thread {
                HStack {
                    Button("Open in Changes") { model.openInChanges(thread.path, line: thread.line, side: thread.side, pr: pr) }
                    if item.status == "addressed", !thread.isResolved, thread.viewerCanResolve {
                        Button("Resolve Conversation") { Task { await model.setResolved(thread, true, pr: pr) } }
                            .disabled(model.pending.contains(thread.id))
                        if model.pending.contains(thread.id) { ProgressView().controlSize(.small) }
                    }
                    if thread.isResolved { Label("Resolved", systemImage: "checkmark.circle").foregroundStyle(.green).font(.callout) }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(FollowUpBadge.color(item.status).opacity(0.4)))
    }
}

struct FollowUpBadge: View {
    let status: String
    var count: Int?

    var body: some View {
        Badge(text: Self.title(status) + (count.map { " · \($0)" } ?? ""), color: Self.color(status))
    }

    static func title(_ status: String) -> String {
        switch status {
        case "addressed": "ADDRESSED"
        case "partial": "PARTLY"
        case "not_addressed": "NOT ADDRESSED"
        case "disputed": "PUSHED BACK"
        default: "UNCLEAR"
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "addressed": .green
        case "partial": .orange
        case "not_addressed": .red
        case "disputed": .purple
        default: .secondary
        }
    }
}
