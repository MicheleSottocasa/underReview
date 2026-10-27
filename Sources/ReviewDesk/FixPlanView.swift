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
                            Text("No open feedback. Reviewers' comments show here.")
                        }
                        .padding(.top, runs.isEmpty ? 40 : 0)
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
        .task { await model.loadDetail(pr.id) }
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

    var body: some View {
        let detail = model.details[pr.id]
        let threads = detail?.threads ?? []
        let reviews = (detail?.reviews ?? []) + (detail?.latestReviews ?? [])
        let choices = model.fixPlanChoices(for: run)
        VStack(alignment: .leading, spacing: 10) {
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
            ForEach(Array(FixPlan.ordered(run.result.items, threads: threads).enumerated()), id: \.offset) { _, item in
                FixPlanItemView(pr: pr, run: run, item: item, thread: threads.first { $0.id == item.sourceID },
                                review: reviews.first { $0.id == item.sourceID }, choice: choices[item.sourceID])
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.25)))
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
    let choice: FixPlanChoice?
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
