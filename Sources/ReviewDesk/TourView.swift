import ReviewDeskCore
import SwiftUI

/// The onboarding tour, walked on the demo stack: one card per area, in this order.
enum TourStep: Int, CaseIterable {
    case sidebar, header, conversation, risk, changes, ai, notes, settings

    var title: String {
        switch self {
        case .sidebar: "Your pull requests"
        case .header: "The pull request"
        case .conversation: "Conversation"
        case .risk: "Risk"
        case .changes: "Changes"
        case .ai: "AI Review"
        case .notes: "Notes"
        case .settings: "Settings"
        }
    }

    var body: String {
        switch self {
        case .sidebar:
            "Grouped by repository. **To Review** holds others' pull requests you're asked to review or assigned to; **My PRs** holds yours, with the reviews others left on them; **Projects** are your own folders (drag pull requests or stacks into them). A GitHub **stack** shows as one group. On each row: ✈ comments not sent yet, ✓ or ! your review, ↻ new commits since your review, ↩ replies you owe.\n\nThis stack is a fictional demo for the tour."
        case .header:
            "Title, repository and number, author, branches (head → base) and the position in its stack. **Open on GitHub** opens it in your browser."
        case .conversation:
            "The description, reviews and comments, in order. Edit, delete or react to comments, resolve conversations, and use ✨ **Explain** or 💬 **Ask** to chat with the AI about a comment.\n\nWhen the author pushes or replies after your review, a **Follow-up** tab checks whether each of your comments was handled (see the stack's first pull request)."
        case .risk:
            "Review risk, not lines: five questions in order (data, access, scale, failure, explain). Each shows the author's Risk notes, the AI's answer and the code to read. Tick each one off once you've checked it."
        case .changes:
            """
            - **File tree** with **All / Focus**: Focus lists the AI's key files and sections, and every file with comments you haven't sent.
            - **Key areas** have a yellow bar in the diff; click one in Focus to jump there.
            - **Inline threads and drafts**: hover a line and click + to draft a comment. Drafts stay on this Mac until you save them.
            - **Split or unified** diff, at the top left.
            - The **review bar**: save drafts to your pending GitHub review, then **Finish Review**.
            """
        case .ai:
            "Pick an engine: Claude Code runs its own `/code-review` (beta); Codex and Ollama review the context you approve (alpha). Findings about code go straight into your pending review as inline comments (only you see them until you submit); general remarks go into your summary. Older analyses are marked outdated after a push."
        case .notes:
            "Private notes on a pull request or a whole stack. They stay on this Mac and are never sent to GitHub."
        case .settings:
            "Refresh intervals, the diff layout, the AI engine, model and effort, and the text of every AI prompt.\n\nReopen this tour anytime from **Help › Show Tour**."
        }
    }

    /// The tab the step shows; nil keeps the conversation behind sidebar and header steps.
    var tab: DetailTab {
        switch self {
        case .sidebar, .header, .conversation, .settings: .conversation
        case .risk: .risk
        case .changes: .changes
        case .ai: .ai
        case .notes: .notes
        }
    }

    var previous: TourStep? { TourStep(rawValue: rawValue - 1) }
    var next: TourStep? { TourStep(rawValue: rawValue + 1) }
}

extension AppModel {
    func startTour() {
        showDemo()
        if let main = prs[Demo.mainID] { reveal(main) }
        showTourStep(.sidebar)
    }

    func showTourStep(_ step: TourStep) {
        if selectedPRID != Demo.mainID { selection = [.pr(Demo.mainID)] }
        detailTab = step.tab
        if step == .sidebar { columns = .all }
        tourStep = step
    }

    /// Skip or Done: the demo goes away with every change made to it, and the tour won't start by itself again.
    func endTour() {
        tourStep = nil
        hideDemo()
        UserDefaults.standard.set(true, forKey: "tourSeen")
    }

    var shouldStartTour: Bool { !UserDefaults.standard.bool(forKey: "tourSeen") }
}

/// A tour card: what this area is, with Back / Next / Skip.
struct TourCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let step: TourStep

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title).font(.headline)
                Spacer()
                Text("\(step.rawValue + 1) of \(TourStep.allCases.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            MarkdownText(step.body).font(.callout)
            if step == .settings { Button("Open Settings") { openSettings() } }
            HStack {
                Button("Skip Tour") { model.endTour() }.buttonStyle(.link)
                Spacer()
                if let previous = step.previous { Button("Back") { model.showTourStep(previous) } }
                Button(step.next == nil ? "Done" : "Next") {
                    if let next = step.next { model.showTourStep(next) } else { model.endTour() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}

extension View {
    /// Shows the tour card for any of `steps` anchored to this view while that step is active.
    func tourAnchor(_ steps: Set<TourStep>, edge: Edge) -> some View {
        modifier(TourAnchor(steps: steps, edge: edge))
    }
}

private struct TourAnchor: ViewModifier {
    @Environment(AppModel.self) private var model
    let steps: Set<TourStep>
    let edge: Edge

    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { model.tourStep.map(steps.contains) == true }, set: { _ in }), arrowEdge: edge) {
            if let step = model.tourStep { TourCard(step: step).interactiveDismissDisabled() }
        }
    }
}
