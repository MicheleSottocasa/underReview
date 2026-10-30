import ReviewDeskCore
import SwiftUI

/// On your own pull request: the feedback reviewers left you and the AI's plan to address it, item by item.
struct FixPlanView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    @AppStorage("aiEngine") private var engineName = "claude"
    @AppStorage("ollamaModel") private var ollamaModel = "qwen2.5-coder"
    @AppStorage("aiBudget") private var budget = 150_000
    /// Each provider's model and effort, shared with AI Review and Settings › AI; "" keeps the CLI's default.
    @AppStorage("claudeModel") private var claudeModel = ""
    @AppStorage(AppModel.claudeContextKey) private var claudeContext = ""
    @AppStorage("codexModel") private var codexModel = ""
    @AppStorage("codexEffort") private var codexEffort = ""
    @AppStorage("ollamaThink") private var ollamaThink = ""
    @ViewState private var context: ReviewContext?
    @ViewState private var partial = false
    @ViewState private var preparing = false
    /// The engine a Re-plan asked for, when it differs from the toolbar's; nil runs with the toolbar's engine.
    @ViewState private var contextEngine: AIEngine?
    /// The model and effort a Re-plan asked for; nil runs with the provider's current ones.
    @ViewState private var contextOptions: AIOptions?
    /// The branch the linked clone is on, to offer Check Out when it isn't the PR's.
    @ViewState private var cloneBranch: String?

    private var engine: AIEngine { model.engine(named: engineName, ollamaModel: ollamaModel, for: pr) }
    /// Claude engines run straight away; Codex and Ollama show the context first.
    private var runsDirectly: Bool { engine.tool == "claude" }

    var body: some View {
        let busy = model.isAIBusy(pr)
        let runs = model.fixPlanRuns(for: pr.id)
        let feedback = model.fixPlanFeedback(pr)
        VStack(spacing: 0) {
            toolbar(busy: busy, feedback: feedback, planned: !runs.isEmpty)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AIProgress(pr: pr)
                    if let context {
                        let runEngine = contextEngine ?? engine
                        ContextPanel(context: Binding(get: { context }, set: { self.context = $0 }), engine: runEngine, answer: .fixPlan) {
                            model.startFixPlan(pr, engine: runEngine, options: contextOptions ?? model.aiOptions(for: runEngine),
                                               prepared: (context: context, partial: partial))
                            self.context = nil
                            contextEngine = nil
                            contextOptions = nil
                        }
                    }
                    if feedback?.isEmpty == true {
                        ContentUnavailableView {
                            Label("No open feedback", systemImage: "checkmark.bubble")
                        } description: {
                            Text("No open feedback. Reviewers' comments, and the findings of an AI review on one of the last \(FixPlan.recentCommits) commits, show here.")
                        }
                        .padding(.top, runs.isEmpty ? 40 : 0)
                    }
                    if let branch = cloneBranch, branch != pr.headRefName, !runs.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(branch.isEmpty ? "The local clone is on a detached HEAD, not \(pr.headRefName)."
                                                    : "The local clone is on \(branch), not \(pr.headRefName).")
                                    .font(.callout)
                                Text("Check it out before fixing, pasting the prompt into an agent or opening files in your editor.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            CheckOutButton(pr: pr)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let run = runs.first {
                        FixPlanRunView(pr: pr, run: run) { replan(run) }
                    } else if feedback?.isEmpty == false, context == nil, !busy {
                        ContentUnavailableView {
                            Label("No fix plan yet", systemImage: "wrench.and.screwdriver")
                        } description: {
                            Text(runsDirectly
                                 ? "Plan Fixes asks \(engine.name) what to do about each comment: change the code, reply or push back, with the steps and a reply to post. Nothing is changed or posted."
                                 : "Prepare the context to see exactly what will be sent, then plan the fixes. Nothing is changed or posted.")
                        }
                        .padding(.top, 40)
                    }
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: budget) { _, value in context?.budget = value }
        .onChange(of: engineName) {
            contextEngine = nil
            contextOptions = nil
        }
        .task {
            await model.loadDetail(pr.id)
            // Open in Editor needs the file's diff.
            if model.files[pr.id] == nil, !pr.isDemo { try? await model.fetchFiles(pr) }
        }
        // Read again when the clone is linked or changed, and after each checkout.
        .task(id: "\(pr.id)|\(model.localClones[pr.repo] ?? "")|\(model.checkingOut.count)") { cloneBranch = await model.cloneBranch(pr) }
        .task(id: engineName) {
            guard engineName == "ollama" else { return }
            await model.loadOllamaModels()
            await model.loadOllamaThinks(ollamaModel)
        }
        .task(id: ollamaModel) { if engineName == "ollama" { await model.loadOllamaThinks(ollamaModel) } }
    }

    private func toolbar(busy: Bool, feedback: FixPlanFeedback?, planned: Bool) -> some View {
        HStack(spacing: 10) {
            Picker("Engine", selection: $engineName) {
                if let link = model.agentLinks[pr.id] { Text("Linked: \(link.name) · beta").tag("linked") }
                Text("Claude Code · beta").tag("claude")
                Text("Codex · alpha").tag("codex")
                Text("Ollama (local) · alpha").tag("ollama")
            }
            .fixedSize()
            // A plan runs on ReviewDesk's prompt: Claude Code keeps the CLI's effort there, as in follow-up checks.
            switch engine {
            case .claudeCode, .claudeSession:
                ModelPicker(choices: AIOptions.models(for: engine), selection: $claudeModel).fixedSize()
                if !claudeModel.isEmpty { ContextPicker(model: claudeModel, selection: $claudeContext).fixedSize() }
            case .codex:
                ModelPicker(choices: AIOptions.models(for: engine), selection: $codexModel).fixedSize()
                EffortPicker(engine: engine, selection: $codexEffort).fixedSize()
            case .ollama:
                ModelPicker(choices: model.ollamaModels.map { ModelChoice($0, $0) }, selection: $ollamaModel, defaultLabel: nil).fixedSize()
                if model.ollamaThinks[ollamaModel] == true {
                    EffortPicker(engine: engine, selection: $ollamaThink).fixedSize()
                }
            }
            if !runsDirectly {
                LabeledContent("Budget") {
                    TextField("", value: $budget, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                }
                .fixedSize()
            }
            if !engine.isLocal {
                Image(systemName: "icloud.and.arrow.up").foregroundStyle(.orange)
                    .help("The feedback and the diff are sent to \(engine.name)'s provider using your CLI login. It runs without tools.")
            }
            Spacer()
            EstimateLabel(estimate: model.fixPlanEstimate(pr, engine: engine), prefix: "up to ",
                          help: "At most: the feedback plus the whole diff (only the files the feedback points at when the whole diff is over the budget). It counts toward your plan's limits.")
            Button(runsDirectly ? (planned ? "Plan Again" : "Plan Fixes") : preparing ? "Preparing…" : "Prepare Context") { start() }
                .buttonStyle(.borderedProminent)
                .disabled(preparing || busy || feedback?.isEmpty != false)
                .help(feedback?.isEmpty != false ? "No open feedback to plan for"
                      : runsDirectly ? "Ask \(engine.name) how to address each piece of open feedback"
                                     : "See exactly what will be sent before planning")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func start() {
        if runsDirectly {
            context = nil
            model.startFixPlan(pr, engine: engine, options: model.aiOptions(for: engine))
        } else {
            prepare()
        }
    }

    /// Plans again with the run's engine, model and effort (the provider's current ones for plans saved without them);
    /// Codex and Ollama show the context first, as always.
    private func replan(_ run: FixPlanRun) {
        if run.engine.tool == "claude" {
            context = nil
            model.startFixPlan(pr, engine: run.engine, options: run.options ?? model.aiOptions(for: run.engine))
        } else {
            prepare(for: run.engine, options: run.options)
        }
    }

    /// `override` is a Re-plan's engine and `options` its model and effort; nil means the toolbar's.
    private func prepare(for override: AIEngine? = nil, options: AIOptions? = nil) {
        contextEngine = override == engine ? nil : override
        contextOptions = options
        preparing = true
        Task {
            do {
                let prepared = try await model.fixPlanContext(pr, budget: budget)
                context = prepared.context
                partial = prepared.partial
            } catch {
                model.report(error)
            }
            preparing = false
        }
    }
}

/// The latest plan: what's outdated, the tally, then one card per item in file order and the general remarks.
private struct FixPlanRunView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let run: FixPlanRun
    let replan: () -> Void
    @ViewState private var confirmingReplies = false
    @ViewState private var copied = false
    @ViewState private var fixing = false

    var body: some View {
        let detail = model.details[pr.id]
        let threads = detail?.threads ?? []
        let reviews = (detail?.reviews ?? []) + (detail?.latestReviews ?? [])
        let findings = model.fixPlanFindings(pr)
        let choices = model.fixPlanChoices(for: run)
        let replies = FixPlan.acceptedReplies(run.result.items, choices: choices, threads: threads, reviews: reviews)
        let changes = run.result.items.filter { $0.action == "change_code" && choices[$0.sourceID]?.decision == .accepted }.count
        let posting = replies.contains { model.pending.contains($0.sourceID) }
        let maybeDone = model.fixPlanMaybeDone(run, pr: pr)
        VStack(alignment: .leading, spacing: 10) {
            if let summary = model.fixRuns[pr.id] {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Fix finished: review the changes in your clone, then commit and push", systemImage: "checkmark.circle.fill")
                            .font(.callout.bold()).foregroundStyle(.green)
                        Spacer()
                        Button("Dismiss") { model.fixRuns[pr.id] = nil }.buttonStyle(.link)
                    }
                    MarkdownText(summary)
                }
                .padding(10)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let reason = model.fixPlanOutdatedReason(run, pr: pr) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reason).font(.callout.bold())
                        Text("Steps, lines and replies may no longer match the code or the conversation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Re-plan", action: replan)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isAIBusy(pr))
                        .help("Plans again with \(run.engine.name)\(run.options.map { ", " + $0.label(for: run.engine) } ?? "")")
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4)))
            }
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.purple)
                Text(run.engine.name).bold()
                if let options = run.options {
                    Text(options.label(for: run.engine)).foregroundStyle(.secondary)
                }
                Text(run.date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                UsageLabel(usage: run.usage)
                if run.partialDiff {
                    Badge(text: "Commented files only", color: .secondary)
                        .help("The whole diff was over the budget, so only the files the feedback points at were sent")
                }
                Spacer()
                Button("Delete") { model.deleteFixPlan(run.id) }.buttonStyle(.link)
            }
            .font(.callout)
            Text(FixPlan.tally(run.result.items)).font(.callout.bold())
            MarkdownText(run.result.summary)
            HStack(spacing: 8) {
                Button("Post Accepted Replies (\(replies.count))") { confirmingReplies = true }
                    .disabled(replies.isEmpty || posting)
                    .help(replies.isEmpty ? "Accept items with a reply to post them all at once"
                                          : "Post the accepted items' replies: in their conversation, or as a comment for a review summary")
                let prompt = { (notes: String) in
                    FixPlan.agentPrompt(pr: model.prs[pr.id] ?? pr, head: run.headRefOid, items: run.result.items, choices: choices,
                                        threads: threads, reviews: reviews, findings: findings, notes: notes)
                }
                Button("Fix (\(changes))…") { fixing = true }
                    .disabled(changes == 0 || model.isAIBusy(pr))
                    .help(changes == 0 ? "Accept items that change the code to fix them with an agent"
                                       : "Have Claude Code or Codex make the accepted code changes in your local clone, in the background, with your own instructions added")
                    .sheet(isPresented: $fixing) { FixAgentSheet(pr: pr, prompt: prompt) }
                Button(copied ? "Copied" : "Copy as Agent Prompt (\(changes))") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt(""), forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .disabled(changes == 0)
                .help(changes == 0 ? "Accept items that change the code to copy them as a prompt"
                                   : "Copy the accepted code changes as one prompt for Claude Code or Codex, to paste into an agent in your local clone. ReviewDesk changes no code itself.")
                if posting { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            .confirmationDialog("Post \(replies.count) repl\(replies.count == 1 ? "y" : "ies")?", isPresented: $confirmingReplies) {
                Button("Post \(replies.count)") { Task { await model.postFixPlanReplies(replies, run: run, pr: pr) } }
            } message: {
                Text(replies.map { "• \($0.label): \($0.body.prefix(80))" }.joined(separator: "\n"))
            }
            ForEach(Array(FixPlan.ordered(run.result.items, threads: threads, findings: findings).enumerated()), id: \.offset) { _, item in
                FixPlanItemView(pr: pr, run: run, item: item, thread: threads.first { $0.id == item.sourceID },
                                review: reviews.first { $0.id == item.sourceID }, finding: findings.first { $0.id == item.sourceID },
                                choice: choices[item.sourceID], maybeDone: maybeDone.contains(item.sourceID))
            }
        }
        .task(id: "\(run.id)|\(model.prs[pr.id]?.headRefOid ?? pr.headRefOid)") { await model.loadFixPlanChanges(run, pr: pr) }
        .padding(14)
        .background(Color.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.25)))
    }
}

/// What Fix sends: the accepted code changes as a prompt, with the author's own instructions added, to Claude Code
/// or Codex, run in the background in the local clone.
private struct FixAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pr: PullRequest
    let prompt: (String) -> String
    @AppStorage("fixAgent") private var tool = "claude"
    @ViewState private var notes = ""

    var body: some View {
        Form {
            Picker("Agent", selection: $tool) {
                Text("Claude Code").tag("claude")
                Text("Codex").tag("codex")
            }
            Section("Additional instructions") {
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 80)
            }
            Section("Prompt") {
                ScrollView {
                    Text(prompt(notes))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
            Text((model.localClones[pr.repo].map { "Runs in the background in \($0), on \(pr.headRefName)." }
                  ?? "Asks for the local clone first, then runs in the background in it.")
                 + " The agent can read and edit the clone's files, but can't run commands, so it doesn't build, test, commit or push. Review its changes before you commit.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    let engine: AIEngine = tool == "codex" ? .codex : .claudeCode
                    model.startFix(pr, engine: engine, options: model.aiOptions(for: engine), prompt: prompt(notes))
                    dismiss()
                }
            }
        }
    }
}

/// One piece of feedback and its plan: the reviewer's comment (the rest of the thread folded), the action, the steps,
/// where to change, and the reply. Accept, Skip and edits are stored locally for this plan.
private struct FixPlanItemView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let run: FixPlanRun
    let item: FixPlanItem
    let thread: ReviewThread?
    let review: Review?
    let finding: FixPlanAIFinding?
    let choice: FixPlanChoice?
    /// Its lines changed in a push since the plan.
    let maybeDone: Bool
    @ViewState private var showsThread = false
    @ViewState private var editing = false
    @ViewState private var stepsText = ""
    @ViewState private var replyText = ""

    var body: some View {
        let steps = choice?.steps ?? item.steps
        let reply = choice?.reply ?? item.reply
        let decision = choice?.decision
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FixPlanBadge(action: item.action)
                Text(inlineMarkdown(item.request, repo: pr.repo)).bold()
                if item.confidence != "high" {
                    Text("\(item.confidence) confidence").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if maybeDone {
                    Badge(text: "Maybe done", color: .green)
                        .help("Its lines changed in a push since this plan. Re-plan to confirm.")
                }
                if choice?.posted == true {
                    Badge(text: "Reply posted", color: .blue)
                }
                if let decision {
                    Badge(text: decision == .accepted ? "Accepted" : "Skipped", color: decision == .accepted ? .green : .secondary)
                }
                Text(verbatim: sourceLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            feedback
            if editing {
                Text("Steps, one per line").font(.caption.bold()).foregroundStyle(.secondary)
                TextEditor(text: $stepsText)
                    .font(.callout)
                    .frame(minHeight: 60, maxHeight: 140)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Text("Reply").font(.caption.bold()).foregroundStyle(.secondary)
                CommentComposer(text: $replyText, placeholder: "The reply to post")
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        let lines = stepsText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        model.setFixPlanChoice(run, item: item.sourceID) { choice in
                            choice.steps = lines
                            choice.reply = replyText
                        }
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else {
                if !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: "\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                Text(inlineMarkdown(step, repo: pr.repo)).font(.callout)
                            }
                        }
                    }
                }
                if !item.locations.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(item.locations, id: \.self) { location in
                            Button(location.label) { model.openInChanges(location.path, line: location.startLine, side: .right, pr: pr) }
                                .buttonStyle(.link)
                                .font(.caption.monospaced())
                                .help(location.startLine == nil ? "Open the file in Changes" : "Open the line in Changes")
                        }
                    }
                }
                if !reply.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Proposed reply").font(.caption.bold()).foregroundStyle(.secondary)
                        MarkdownText(reply).font(.callout)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack {
                Button(decision == .accepted ? "Accepted" : "Accept") {
                    model.setFixPlanChoice(run, item: item.sourceID) { $0.decision = $0.decision == .accepted ? nil : .accepted }
                }
                .help(decision == .accepted ? "Click to undo" : "Keep this item in the plan")
                Button(decision == .skipped ? "Skipped" : "Skip") {
                    model.setFixPlanChoice(run, item: item.sourceID) { $0.decision = $0.decision == .skipped ? nil : .skipped }
                }
                .help(decision == .skipped ? "Click to undo" : "Leave this item out")
                if !editing {
                    Button("Edit") {
                        stepsText = steps.joined(separator: "\n")
                        replyText = reply
                        editing = true
                    }
                    .help("Edit the steps and the reply; the plan's own stay in the stored result")
                }
                if let thread {
                    Button("Open in Changes") { model.openInChanges(thread.path, line: thread.line, side: thread.side, pr: pr) }
                } else if let finding, let path = finding.finding.path {
                    Button("Open in Changes") { model.openInChanges(path, line: finding.finding.line, pr: pr) }
                }
                if let location = item.locations.first, let file = model.files[pr.id]?.first(where: { $0.filename == location.path }) {
                    Button("Open in Editor") { Task { await model.openInEditor(pr, file: file, line: location.startLine) } }
                        .help("Open \(location.label) from the local clone in your editor (Settings › Repositories)")
                }
                if let posting = FixPlan.reply(item.applying(choice), threads: thread.map { [$0] } ?? [], reviews: review.map { [$0] } ?? []),
                   choice?.posted != true, !editing {
                    Button("Post Reply") { Task { await model.postFixPlanReplies([posting], run: run, pr: pr) } }
                        .disabled(model.pending.contains(item.sourceID))
                        .help(thread == nil ? "Post the reply as a comment on the pull request, quoting the review"
                                            : "Post the reply in its conversation")
                    if model.pending.contains(item.sourceID) { ProgressView().controlSize(.small) }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .opacity(decision == .skipped ? 0.6 : 1)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(FixPlanBadge.color(item.action).opacity(0.4)))
    }

    /// Where the feedback is: the thread's file and line, or the review's author.
    private var sourceLabel: String {
        if let thread { return thread.line.map { "\(thread.path):\($0)" } ?? thread.path }
        if let review { return "Review by \(review.author)" }
        if let finding { return finding.location.map { "AI review · \($0)" } ?? "AI review" }
        return "General"
    }

    /// The reviewer's comment: the thread's first one with the replies folded under it, or the review's summary.
    @ViewBuilder private var feedback: some View {
        if let thread {
            let comments = thread.comments.filter { !$0.isPending }
            if let first = comments.first {
                if comments.count > 1 {
                    DisclosureGroup(isExpanded: $showsThread) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(comments.dropFirst()) { reply in quoted(reply.author, reply.body) }
                        }
                        .padding(.top, 4)
                    } label: {
                        quoted(first.author, first.body)
                    }
                } else {
                    quoted(first.author, first.body)
                }
            }
        } else if let review {
            quoted(review.author, review.body)
        } else if let finding {
            quoted("AI review (\(finding.reviewer)) · \(finding.finding.severity)", "**\(finding.finding.title)**\n\n\(finding.finding.comment)")
        }
    }

    private func quoted(_ author: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(author).font(.caption.bold()).foregroundStyle(.secondary)
            MarkdownText(body).font(.callout)
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2) }
    }
}

struct FixPlanBadge: View {
    let action: String

    var body: some View {
        Badge(text: Self.title(action), color: Self.color(action))
    }

    static func title(_ action: String) -> String {
        switch action {
        case "change_code": "CHANGE CODE"
        case "reply_only": "REPLY ONLY"
        case "push_back": "PUSH BACK"
        case "already_done": "ALREADY DONE"
        default: "UNCLEAR"
        }
    }

    static func color(_ action: String) -> Color {
        switch action {
        case "change_code": .orange
        case "reply_only": .blue
        case "push_back": .purple
        case "already_done": .green
        default: .secondary
        }
    }
}
