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
            Button("Check if Addressed") {
                model.detailTab = .followUp
                model.startFollowUp(pr)
            }
            .disabled(model.aiStatus[pr.id] != nil)
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
                    Button(runs.isEmpty ? "Check Now" : "Check Again") { model.startFollowUp(pr) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.aiStatus[pr.id] != nil || (threads.isEmpty && detail.map { FollowUp.reviewBodies(of: model.viewer, in: $0) }?.isEmpty != false))
                        .help("Uses \(model.preferredEngine(for: pr).name), the engine picked in the AI Review tab")
                }
                if model.aiStatus[pr.id] != nil { AIStatusBox(pr: pr) }
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
        .task { await model.loadDetail(pr.id) }
    }
}

private struct FollowUpRunView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let run: FollowUpRun

    var body: some View {
        let counts = Dictionary(grouping: run.result.items, by: \.status).mapValues(\.count)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").foregroundStyle(.purple)
                Text(run.engine.name).bold()
                Text(run.date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
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
            ForEach(Array(run.result.items.enumerated()), id: \.offset) { _, item in
                FollowUpItemView(pr: pr, item: item, thread: item.threadID.flatMap { id in model.details[pr.id]?.threads.first { $0.id == id } })
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.25)))
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
                Text(inlineMarkdown(item.request)).bold()
                Spacer()
                Text(verbatim: thread.map { "\($0.path)\($0.line.map { ":\($0)" } ?? "")" } ?? "Review summary")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            MarkdownText(item.explanation).font(.callout)
            if let thread {
                HStack {
                    Button("Open in Changes") { model.openInChanges(thread.path, line: thread.line, pr: pr) }
                    if item.status == "addressed", !thread.isResolved, thread.viewerCanResolve {
                        Button("Resolve Conversation") { Task { await model.setResolved(thread, true, pr: pr) } }
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
