import ReviewDeskCore
import SwiftUI

enum DetailTab: String, CaseIterable {
    case conversation = "Conversation", fixPlan = "Fix Plan", followUp = "Follow-up", risk = "Risk", changes = "Changes", ai = "AI Review", notes = "Notes"

    /// The tabs of `pr`. Your own pull request gets Fix Plan instead of Follow-up and Risk, which ask a reviewer's
    /// questions; AI Review stays as a self-review. Follow-up only shows when there's something to check or a past
    /// check to read. In a stack, each member gets its own set.
    static func tabs(for pr: PullRequest, showsFollowUp: Bool) -> [DetailTab] {
        pr.viewerIsAuthor ? [.conversation, .fixPlan, .changes, .ai, .notes]
            : allCases.filter { $0 != .fixPlan && ($0 != .followUp || showsFollowUp) }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        @Bindable var model = model
        let tabs = DetailTab.tabs(for: pr, showsFollowUp: !pr.viewerIsAuthor && model.showsFollowUp(pr))
        let tab = tabs.contains(model.detailTab) ? model.detailTab : model.defaultTab(pr, tabs: tabs)
        VStack(alignment: .leading, spacing: 0) {
            if pr.isDemo {
                Label("Demo pull request for the tour: fictional, read-only, never saved or sent anywhere.", systemImage: "graduationcap")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(Color.purple.opacity(0.1))
            }
            header.padding().tourAnchor([.header], edge: .bottom)
            if tabs.contains(.followUp), model.isFollowUpDue(pr), tab != .followUp, model.followUpRuns(for: pr.id).first?.headRefOid != pr.headRefOid {
                FollowUpNotice(pr: pr).padding(.horizontal).padding(.bottom, 8)
            }
            Picker("", selection: Binding(get: { tab }, set: { model.detailTab = $0 })) {
                ForEach(tabs, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .tourAnchor([.conversation, .risk, .changes, .ai, .notes, .settings], edge: .bottom)
            Divider().padding(.top, 8)
            switch tab {
            case .conversation: ConversationView(pr: pr, detail: model.details[pr.id])
            case .fixPlan: FixPlanView(pr: pr)
            case .followUp: FollowUpView(pr: pr)
            case .risk: RiskView(pr: pr)
            case .changes: ChangesView(pr: pr)
            case .ai: AIView(pr: pr)
            case .notes: NotesView(pr: pr)
            }
        }
        .modifier(LinkHandler(pr: pr))
        // Opening your own PR with feedback to address lands on Fix Plan, unless another tab was picked on purpose.
        .onChange(of: pr.id, initial: true) {
            if model.detailTab == .conversation, model.defaultTab(pr, tabs: tabs) == .fixPlan { model.detailTab = .fixPlan }
        }
        // Changes takes the whole window, like a diff editor; only restore a sidebar the app hid itself.
        .onChange(of: tab, initial: true) { _, tab in
            if tab == .changes, model.columns != .detailOnly {
                model.columns = .detailOnly
                model.sidebarAutoHidden = true
            } else if tab != .changes, model.sidebarAutoHidden {
                model.columns = .all
                model.sidebarAutoHidden = false
            }
        }
    }

    /// Title and actions; then who and where (repo, number, author, branches, size); then where it stands
    /// (state, merge, my review, reviewers).
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(pr.title).font(.title2.bold()).textSelection(.enabled)
                Spacer()
                CheckOutButton(pr: pr)
                if let stack = pr.stack { StackStepper(pr: pr, stack: stack) }
                Button("Open on GitHub") { model.openOnGitHub(pr) }
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text(pr.repo).foregroundStyle(.secondary)
                    Text(verbatim: "#\(pr.number)").fontWeight(.semibold)
                }
                .textSelection(.enabled)
                Label(pr.author, systemImage: "person").foregroundStyle(.secondary).help("Author")
                HStack(spacing: 4) {
                    BranchChip(name: pr.headRefName)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    BranchChip(name: pr.baseRefName)
                }
                .help("Merges \(pr.headRefName) into \(pr.baseRefName)")
                if let head = URL(string: "https://github.com/\(pr.repo)/commit/\(pr.headRefOid)") {
                    let headline = model.details[pr.id]?.commits.first { $0.oid == pr.headRefOid }?.headline
                    Link(String(pr.headRefOid.prefix(7)), destination: head).font(.caption.monospaced()).foregroundStyle(.tint)
                        .help(headline.map { "The head commit: \($0)" } ?? "The head commit")
                        .contextMenu { Button("Copy SHA") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pr.headRefOid, forType: .string) } }
                }
                if pr.changedFiles > 0 {
                    HStack(spacing: 4) {
                        Text("+\(pr.additions)").foregroundStyle(.green)
                        Text("−\(pr.deletions)").foregroundStyle(.red)
                    }
                    .monospacedDigit()
                    .help("\(pr.additions) lines added and \(pr.deletions) removed in \(pr.changedFiles) file\(pr.changedFiles == 1 ? "" : "s")")
                }
            }
            .font(.callout)
            .lineLimit(1)
            // One line when it fits, the reviewers on their own line when it doesn't.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { status; reviewers }
                VStack(alignment: .leading, spacing: 6) { status; reviewers }
            }
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            StateBadge(pr: pr)
            MergeBadges(pr: pr)
            if model.hasOutdatedAnalysis(pr) {
                Button { model.detailTab = .ai } label: { Badge(text: "AI analysis outdated", color: .orange) }
                    .buttonStyle(.plain)
                    .help("The author pushed after the latest AI analysis. Open AI Review to run it again.")
            }
            MyReviewStatus(pr: pr)
        }
        .fixedSize()
    }

    @ViewBuilder private var reviewers: some View {
        if let detail = model.details[pr.id] { ReviewersRow(pr: pr, detail: detail).fixedSize() }
    }
}

/// A branch name; click to copy it.
struct BranchChip: View {
    let name: String
    @ViewState private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "arrow.triangle.branch")
                Text(name).truncationMode(.middle)
            }
            .font(.caption.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy “\(name)”")
    }
}

/// Position in the stack (as GitHub numbers it: 1 is closest to the base). The arrows step to the pull request
/// below or above; the middle lists every member to jump to.
struct StackStepper: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let stack: StackInfo

    var body: some View {
        let (below, above) = stack.neighbors(of: pr.id)
        HStack(spacing: 2) {
            step(below, symbol: "chevron.down", direction: "below")
            Menu {
                ForEach(stack.entries, id: \.id) { entry in
                    Button("\(entry.position). #\(entry.number) \(model.prs[entry.id]?.title ?? "")") { go(entry) }
                        .disabled(entry.id == pr.id || model.prs[entry.id] == nil)
                }
            } label: {
                Text(verbatim: "Stack #\(stack.number) · \(pr.stackPosition ?? 0) of \(stack.entries.count)").monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pull requests built on top of each other: 1 is closest to the base branch. Click to jump to another one.")
            step(above, symbol: "chevron.up", direction: "above")
        }
        .padding(.horizontal, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func step(_ entry: StackInfo.Entry?, symbol: String, direction: String) -> some View {
        Button { entry.map(go) } label: { Image(systemName: symbol).frame(width: 16, height: 16) }
            .buttonStyle(.borderless)
            .disabled(entry.flatMap { model.prs[$0.id] } == nil)
            .help(entry.map { "Go to #\($0.number), \(direction) this one in the stack" } ?? "Nothing \(direction) this one in the stack")
    }

    private func go(_ entry: StackInfo.Entry) {
        guard let target = model.prs[entry.id] else { return }
        model.reveal(target)
        model.selection = [.pr(target.id)]
    }
}

/// Where the viewer's own review stands: in full in the header, compact in the Changes review bar
/// (which counts pending comments itself).
struct MyReviewStatus: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    var compact = false
    @ViewState private var showsWaiting = false

    var body: some View {
        let status = model.reviewStatus(pr)
        let viewer = model.viewer(for: pr)
        let waiting = model.details[pr.id]?.threadsAwaitingReply(pr, viewer: viewer) ?? []
        let requested = !pr.viewerIsAuthor && pr.requestedReviewers.contains(viewer)
        HStack(spacing: 6) {
            if let state = pr.viewerReviewState, let label = ReviewIndicator.label(state) {
                Pill(text: "You: \(label.text)", symbol: label.symbol, color: label.color)
                    .help("Your latest review")
                if requested {
                    Pill(text: "re-requested", symbol: "eye", color: .secondary)
                        .help("Your review was requested again after you reviewed")
                }
            } else if requested {
                Pill(text: "Your review is requested", symbol: "eye", color: .secondary)
            }
            if status.changedSinceReview {
                Button { model.openChangesSinceReview(pr) } label: {
                    Pill(text: "on an older commit", symbol: "arrow.triangle.2.circlepath", color: .orange)
                }
                .buttonStyle(.plain)
                .help("The author pushed after your review. Click to see the new commits on GitHub.")
            }
            if !compact, status.hasPendingReview {
                Button { model.detailTab = .changes } label: {
                    Pill(text: status.toSend == 0 ? "Pending review" : "\(status.toSend) pending comment\(status.toSend == 1 ? "" : "s")",
                         symbol: "paperplane.fill", color: .orange)
                }
                .buttonStyle(.plain)
                .help("Your review isn't sent yet: only you can see it. Click to open Changes and finish it.")
            }
            if !waiting.isEmpty {
                Button { showsWaiting = true } label: {
                    Pill(text: "\(waiting.count) waiting for your reply", symbol: "arrowshape.turn.up.left.fill", color: .purple)
                }
                .buttonStyle(.plain)
                .help("Conversations where someone answered you and it's your turn")
                .popover(isPresented: $showsWaiting, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(waiting) { thread in
                            Button {
                                showsWaiting = false
                                model.openInChanges(thread.path, line: thread.line, pr: pr)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: "\(thread.path)\(thread.line.map { ":\($0)" } ?? "")").font(.caption.monospaced())
                                    Text(verbatim: "\(thread.comments.last?.author ?? ""): \(thread.comments.last?.body ?? "")")
                                        .lineLimit(1).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    .frame(maxWidth: 420, alignment: .leading)
                }
            }
        }
    }
}

/// GitHub's Reviewers box on one line: the merge decision, then everyone else's latest review or pending request.
struct ReviewersRow: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let detail: PRDetail

    var body: some View {
        let reviewers = detail.reviewers(of: pr, viewer: model.viewer(for: pr))
        if detail.reviewDecision != nil || !reviewers.isEmpty {
            HStack(spacing: 10) {
                Text("Reviewers").foregroundStyle(.secondary)
                if let (text, color) = Self.decision(detail.reviewDecision) {
                    Pill(text: text, color: color).help("GitHub's review decision: whether the reviews so far allow merging")
                }
                // ponytail: one line; past 6 reviewers the rest go in the tooltip, wrap them if that's common.
                ForEach(reviewers.prefix(6), id: \.login) { reviewer in
                    let label = reviewer.state.flatMap(ReviewIndicator.label)
                    HStack(spacing: 3) {
                        Image(systemName: label?.symbol ?? "clock").foregroundStyle(label?.color ?? .secondary)
                        Text(reviewer.login)
                    }
                    .opacity(reviewer.isOutdated ? 0.6 : 1)
                    .help("\(reviewer.login): \(label?.text ?? "review requested")\(reviewer.isOutdated ? ", on an older commit" : "")")
                }
                if reviewers.count > 6 {
                    Text(verbatim: "+\(reviewers.count - 6)").foregroundStyle(.secondary)
                        .help(reviewers.dropFirst(6).map(\.login).joined(separator: ", "))
                }
            }
            .font(.callout)
        }
    }

    static func decision(_ decision: String?) -> (String, Color)? {
        switch decision {
        case "APPROVED": ("Approved", .green)
        case "CHANGES_REQUESTED": ("Changes requested", .red)
        case "REVIEW_REQUIRED": ("Review required", .orange)
        default: nil
        }
    }
}

struct NotesView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        Form {
            Section("Private note on this pull request") { editor(key: "pr:\(pr.id)") }
            if pr.stack != nil {
                Section("Private note on the whole stack") { editor(key: pr.itemKey) }
            }
            Text("Notes stay on this Mac and are never sent to GitHub.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func editor(key: String) -> some View {
        TextEditor(text: Binding(
            get: { model.org.notes[key] ?? "" },
            set: { model.org.notes[key] = $0.isEmpty ? nil : $0 }
        ))
        .font(.body)
        .frame(minHeight: 120)
    }
}

/// *Conflicts* (opens GitHub's conflict page) and *Behind <base>* (opens the PR, where it can be updated).
/// Nothing while GitHub is still computing mergeability.
struct MergeBadges: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        if pr.hasConflicts {
            badge("Conflicts", color: .red) { model.openConflicts(pr) }
                .help("Has conflicts with \(pr.baseRefName). Click to resolve them on GitHub.")
        }
        if pr.isBehind {
            badge("Behind \(pr.baseRefName)", color: .orange) { model.openOnGitHub(pr) }
                .help("\(pr.baseRefName) has commits this branch doesn't have yet. Click to update it on GitHub.")
        }
    }

    private func badge(_ text: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) { Image(systemName: "exclamationmark.triangle.fill"); Text(text) }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }
}
