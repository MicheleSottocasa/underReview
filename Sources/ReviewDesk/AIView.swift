import ReviewDeskCore
import SwiftUI

struct AIView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    @AppStorage("aiEngine") private var engineName = "claude"
    @AppStorage("ollamaModel") private var ollamaModel = "qwen2.5-coder"
    @AppStorage("aiBudget") private var budget = 150_000
    /// Last used model and effort for `/code-review`; "" keeps the CLI's default model.
    @AppStorage("claudeModel") private var claudeModel = ""
    @AppStorage("reviewEffort") private var effort = "high"
    @ViewState private var context: ReviewContext?
    @ViewState private var preparing = false

    private var engine: AIEngine { model.engine(named: engineName, ollamaModel: ollamaModel, for: pr) }
    private var usesCodeReview: Bool { engine.tool == "claude" }
    private var options: CodeReviewOptions { CodeReviewOptions(model: claudeModel, effort: effort) }

    var body: some View {
        let busy = model.isAIBusy(pr)
        let runs = model.runs(for: pr.id)
        VStack(spacing: 0) {
            toolbar(busy: busy)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LinkedAgentCard(pr: pr) {
                        engineName = "linked"
                        start()
                    }
                    AIProgress(pr: pr)
                    if let context {
                        ContextPanel(context: Binding(get: { context }, set: { self.context = $0 }), engine: engine) {
                            model.startReview(pr, engine: engine, context: context)
                            self.context = nil
                        }
                    }
                    ForEach(runs) { RunView(pr: pr, run: $0) }
                    if runs.isEmpty && context == nil && !busy && model.stackRun(for: pr) == nil {
                        ContentUnavailableView {
                            Label("No AI reviews yet", systemImage: "sparkles")
                        } description: {
                            Text(usesCodeReview
                                 ? "Run Claude Code's /code-review on this PR. Findings stay here until you add them to your review."
                                 : "Prepare the context to see exactly what will be sent, then run the review. Findings stay here until you add them to your review.")
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
        .task { await model.refreshAgents() }
    }

    private func toolbar(busy: Bool) -> some View {
        HStack(spacing: 10) {
            Picker("Engine", selection: $engineName) {
                if let link = model.agentLinks[pr.id] { Text("Linked: \(link.name) · beta").tag("linked") }
                Text("Claude Code · beta").tag("claude")
                Text("Codex · alpha").tag("codex")
                Text("Ollama (local) · alpha").tag("ollama")
            }
            .fixedSize()
            if engineName == "ollama" {
                TextField("Model", text: $ollamaModel).frame(width: 140)
            }
            if usesCodeReview {
                Picker("Model", selection: $claudeModel) {
                    Text("Default").tag("")
                    Text("Fable").tag("fable")
                    Text("Opus").tag("opus")
                    Text("Sonnet").tag("sonnet")
                    Text("Haiku").tag("haiku")
                }
                .fixedSize()
                Picker("Effort", selection: $effort) {
                    ForEach(CodeReviewOptions.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .fixedSize()
            } else {
                LabeledContent("Budget") {
                    TextField("", value: $budget, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                }
                .fixedSize()
            }
            if !engine.isLocal {
                Image(systemName: "icloud.and.arrow.up").foregroundStyle(.orange)
                    .help(usesCodeReview
                          ? "Claude Code reads the PR through `gh pr diff` / `gh pr view` (read-only) and sends it to \(engine.name)'s provider using your CLI login."
                          : "The selected code is sent to \(engine.name)'s provider using your CLI login.")
            }
            Spacer()
            if let stack = model.allItems.first(where: { $0.key == pr.itemKey && $0.isStack }) {
                // PRs you already approved are done for you: no new agent on them.
                let toReview = Stacks.toReview(stack.pullRequests)
                Button("Review Stack (\(toReview.count))") {
                    model.startStackReview(toReview, engine: engine, budget: budget, options: options, from: pr.id)
                }
                .disabled(busy || toReview.isEmpty)
                .help(toReview.isEmpty ? "Every open PR of this stack is approved by you"
                                       : "One agent per open PR you haven't approved, several at once (Settings › AI)")
            }
            Button(usesCodeReview ? "Run /code-review" : preparing ? "Preparing…" : "Prepare Context") { start() }
                .buttonStyle(.borderedProminent)
                .disabled(preparing || busy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Claude engines run `/code-review` straight away; the others show the context first.
    private func start() {
        if usesCodeReview {
            context = nil
            model.startCodeReview(pr, engine: engine, options: options)
        } else {
            prepare()
        }
    }

    private func prepare() {
        preparing = true
        Task {
            do { context = try await model.prepareContext(pr, budget: budget) } catch { model.lastError = error.localizedDescription }
            preparing = false
        }
    }
}

/// Shows exactly what will be sent; the user trims it to fit instead of the app truncating.
struct ContextPanel: View {
    @Binding var context: ReviewContext
    let engine: AIEngine
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Context to send").font(.headline)
                Spacer()
                Text("\(context.tokens.formatted()) / \(context.budget.formatted()) tokens")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(context.fitsBudget ? Color.secondary : Color.red)
            }
            .padding(12)
            Divider()
            ForEach($context.files) { $file in
                HStack {
                    Toggle(isOn: $file.included) { Text(file.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle) }
                        .disabled(file.excludedReason != nil)
                    Spacer()
                    if let reason = file.excludedReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    } else {
                        if file.content == nil { Text("diff only").font(.caption).foregroundStyle(.secondary) }
                        Text("\(file.tokens.formatted())").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }
            if !context.rules.isEmpty {
                Divider()
                Text("Repository rules (base branch): checked against the change").font(.caption.bold()).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                ForEach($context.rules) { $rule in
                    HStack {
                        Toggle(isOn: $rule.included) { Text(rule.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle) }
                        Spacer()
                        Text("\(rule.tokens.formatted())").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
            }
            Divider()
            HStack {
                Text(context.fitsBudget
                     ? "Submodules and Git LFS content are not fetched."
                     : "Over budget: deselect files or raise the budget. Nothing is truncated automatically.")
                    .font(.caption)
                    .foregroundStyle(context.fitsBudget ? Color.secondary : Color.red)
                Spacer()
                Button("Run with \(engine.name)", action: run).buttonStyle(.borderedProminent).disabled(!context.fitsBudget)
            }
            .padding(12)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }
}

struct RunView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let run: AIRun

    var body: some View {
        let outdated = run.headRefOid != pr.headRefOid
        let (inline, _) = AIContext.validate(run.result, files: model.files[pr.id] ?? [])
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(run.engine.name).bold()
                if let options = run.options {
                    Text("/code-review · \(options.model.isEmpty ? "default model" : options.model.capitalized) · \(options.effort)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text(run.date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                if outdated { Badge(text: "Outdated by push", color: .orange) }
                Spacer()
                Button("Delete") { model.deleteRun(run.id) }.buttonStyle(.link)
            }
            .font(.callout)
            MarkdownText(run.result.summary)
            if !run.result.keyAreas.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Read before submitting (Changes › Focus)", systemImage: "scope").font(.callout.bold())
                    ForEach(Array(run.result.keyAreas.enumerated()), id: \.offset) { _, area in
                        (Text(verbatim: "\(area.path) · \(FileTree.lines(area))  ").font(.caption.monospaced()).foregroundColor(.secondary)
                            + Text(inlineMarkdown(area.reason)).font(.caption))
                    }
                }
                .padding(10)
                .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(Array(run.result.findings.enumerated()), id: \.offset) { index, finding in
                FindingCard(finding: finding, isInline: !outdated && inline.contains(finding), handled: run.handled.contains(index)) {
                    model.accept(run.id, finding: index)
                } dismiss: {
                    model.dismiss(run.id, finding: index)
                }
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.25)))
        .task { if model.files[pr.id] == nil { await model.loadFiles(pr) } }
    }
}

struct FindingCard: View {
    let finding: Finding
    let isInline: Bool
    let handled: Bool
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Badge(text: finding.severity.uppercased(), color: color)
                Text(finding.title).bold()
                Spacer()
                Text(verbatim: isInline ? "\(finding.path ?? ""):\(finding.line ?? 0)" : "General")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(inlineMarkdown(finding.rationale)).font(.callout).foregroundStyle(.secondary)
            MarkdownText(finding.comment).font(.callout)
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            if !handled {
                HStack {
                    Button(isInline ? "Add as Draft Comment" : "Add to Review Summary", action: accept)
                    Button("Dismiss", action: dismiss).buttonStyle(.link)
                }
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.35)))
        .opacity(handled ? 0.5 : 1)
    }

    private var color: Color {
        switch finding.severity {
        case "critical", "high": .red
        case "medium": .orange
        default: .secondary
        }
    }
}

/// The Claude Code session linked to this PR, or a prompt to link one.
struct LinkedAgentCard: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let review: () -> Void
    @AppStorage("aiEngine") private var engineName = "claude"
    @ViewState private var picking = false
    @ViewState private var logs: String?
    @ViewState private var confirmingStop: RunningAgent?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Linked agent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let link = model.agentLinks[pr.id] {
                let running = model.runningAgent(for: link)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "apple.terminal").font(.title3).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(link.name).bold().lineLimit(1)
                            AgentStatus(status: running?.status)
                            Spacer()
                            actions(running)
                        }
                        Text(link.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Review with This Agent", action: review)
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                            .help("Runs the review in a fork of the session: it reuses the agent's context and never writes back into it.")
                    }
                }
            } else {
                HStack {
                    Image(systemName: "apple.terminal").font(.title3).foregroundStyle(.tertiary).frame(width: 24)
                    Text("Link a running Claude Code session to review with its context of the code.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Link Agent…") { picking = true }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        .sheet(isPresented: $picking) {
            AgentPicker(pr: pr) { agent in
                model.link(agent, to: pr)
                engineName = "linked"
                picking = false
            } cancel: { picking = false }
        }
        .sheet(item: Binding(get: { logs.map(LogText.init) }, set: { if $0 == nil { logs = nil } })) { log in
            VStack(alignment: .leading) {
                ScrollView { Text(log.text.isEmpty ? "No output." : log.text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Close") { logs = nil }.keyboardShortcut(.cancelAction) }
            }
            .padding()
            .frame(width: 720, height: 460)
        }
        .confirmationDialog("Stop this agent?", isPresented: Binding(get: { confirmingStop != nil }, set: { if !$0 { confirmingStop = nil } })) {
            Button("Stop Agent", role: .destructive) {
                if let agent = confirmingStop { Task { await model.stop(agent) } }
            }
        } message: {
            Text("Its conversation is kept; you can reopen it with `claude attach`.")
        }
    }

    private func actions(_ running: RunningAgent?) -> some View {
        Menu {
            if let running, running.isBackground {
                Button("Open in Terminal") { Task { await model.openInTerminal(running) } }
                Button("Show Logs") { Task { logs = await model.logs(running) } }
                Divider()
                Button("Stop Agent…") { confirmingStop = running }
            } else if let running {
                Text(verbatim: "Running in a terminal (pid \(running.pid ?? 0))")
            }
            Divider()
            Button("Change Agent…") { picking = true }
            Button("Unlink") {
                model.unlink(pr)
                if engineName == "linked" { engineName = "claude" }
            }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// Searchable list of the repo's Claude Code sessions: running ones, then recent stored ones.
struct AgentPicker: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let choose: (RunningAgent) -> Void
    let cancel: () -> Void
    @ViewState private var query = ""
    @ViewState private var selection: String?

    var body: some View {
        let matches = { (agent: RunningAgent) in
            query.isEmpty || agent.name.localizedCaseInsensitiveContains(query) || agent.cwd.localizedCaseInsensitiveContains(query)
                || (agent.branch ?? "").localizedCaseInsensitiveContains(query)
        }
        let running = ClaudeAgents.inScope(model.runningAgents, for: pr.ref).filter(matches)
        let recent = model.recentSessions(for: pr).filter(matches)
        VStack(alignment: .leading, spacing: 10) {
            Text("Link a Claude Code agent").font(.headline)
            Text("Claude Code sessions in a checkout of \(pr.repo). Stopped ones work too: the review resumes them as a fork.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search agents", text: $query).textFieldStyle(.plain)
                Button { Task { await model.refreshAgents() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh running agents")
            }
            .padding(6)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            List(selection: $selection) {
                if !running.isEmpty {
                    Section("Running") { ForEach(running) { row($0) } }
                }
                if !recent.isEmpty {
                    Section("Recent sessions") { ForEach(recent) { row($0) } }
                }
            }
            .listStyle(.inset)
            .overlay {
                if running.isEmpty && recent.isEmpty {
                    ContentUnavailableView("No agents in \(pr.repo)", systemImage: "apple.terminal",
                                           description: Text("Start `claude` in a checkout of this repo, then refresh."))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Link") {
                    if let agent = (model.runningAgents + model.recentSessions).first(where: { $0.id == selection }) { choose(agent) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 600, height: 600)
        .task { await model.refreshAgents() }
    }

    private func row(_ agent: RunningAgent) -> some View {
        HStack(spacing: 10) {
            AgentStatus(status: agent.updatedAt == nil ? agent.status : nil, compact: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).lineLimit(1)
                Text(agent.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~") + (agent.branch.map { " · \($0)" } ?? ""))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let date = agent.updatedAt {
                Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(agent.isBackground ? "background" : "terminal").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .tag(agent.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { choose(agent) }
    }
}

/// Colored dot plus status text, like a presence indicator.
struct AgentStatus: View {
    let status: String?
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            if !compact { Text(status ?? "not running").font(.caption).foregroundStyle(.secondary) }
        }
        .help(status ?? "not running")
    }

    private var color: Color {
        switch status {
        case "idle": .green
        case "busy", "working", "running": .blue
        case "blocked": .orange
        default: .gray
        }
    }
}

private struct LogText: Identifiable {
    let text: String
    var id: String { text }
}

/// A running review: what it's doing, how long it's been going, and its latest steps as they stream in.
struct AIStatusBox: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        let steps = model.aiActivity[pr.id] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.aiStatus[pr.id] ?? "Working…")
                Spacer()
                // Counted from the first step, kept in the model, so switching tabs doesn't restart it.
                if let started = steps.first?.date {
                    Text(started, style: .timer).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Cancel") { model.cancelReview(pr.id) }
            }
            if !steps.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(steps) { step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(step.date, format: .dateTime.hour().minute().second())
                                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                    MarkdownText(step.text).font(.callout)
                                        .foregroundStyle(step.id == steps.last?.id ? .primary : .secondary)
                                }
                                .id(step.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .onChange(of: steps.last?.id) { _, last in withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// What's running for this PR: a stack review it started or is part of (one row per agent), or its own run.
struct AIProgress: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        if let (root, run) = model.stackRun(for: pr) {
            StackRunBox(root: root, run: run, current: pr.id)
        } else if model.aiStatus[pr.id] != nil {
            AIStatusBox(pr: pr)
        }
    }
}

/// A stack review: one row per PR with its agent's state and live log; click a row to open that PR.
struct StackRunBox: View {
    @Environment(AppModel.self) private var model
    let root: String
    let run: StackRun
    let current: String
    @ViewState private var expanded: Set<String> = []

    var body: some View {
        let done = run.states.values.filter { if case .done = $0 { true } else { false } }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !run.isFinished { ProgressView().controlSize(.small) }
                Text(run.isFinished ? "Stack reviewed: \(done) of \(run.members.count) done" : "Reviewing the stack: one agent per pull request")
                    .font(.callout.bold())
                Spacer()
                Button(run.isFinished ? "Dismiss" : "Cancel All") { model.cancelStackRun(root) }
            }
            ForEach(run.members, id: \.self) { id in
                row(id, state: run.states[id] ?? .waiting)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func row(_ id: String, state: StackRun.State) -> some View {
        let pr = model.prs[id]
        let steps = model.aiActivity[id] ?? []
        // The running agents' logs are open; finished ones fold away unless opened.
        let open = expanded.contains(id) != (state == .running)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                icon(state).frame(width: 16)
                Button {
                    model.selection = [.pr(id)]
                } label: {
                    Text(verbatim: pr.map { "#\($0.number) \($0.title)" } ?? id)
                        .lineLimit(1)
                        .fontWeight(id == current ? .semibold : .regular)
                }
                .buttonStyle(.link)
                .help("Open this pull request's AI Review")
                Spacer()
                Text(detail(state, pr: id)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if state == .running || state == .waiting {
                    Button { model.cancelReview(id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help("Stop this agent only")
                }
                if !steps.isEmpty {
                    Button { expanded.formSymmetricDifference([id]) } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help(open ? "Hide this agent's log" : "Show this agent's log")
                }
            }
            if open, !steps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(steps.suffix(6)) { step in
                        MarkdownText(step.text).font(.caption)
                            .foregroundStyle(step.id == steps.last?.id ? .primary : .secondary)
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder
    private func icon(_ state: StackRun.State) -> some View {
        switch state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private func detail(_ state: StackRun.State, pr id: String) -> String {
        switch state {
        case .waiting: "Waiting for a free agent"
        case .running: model.aiStatus[id] ?? "Running"
        case .done(let findings): findings == 0 ? "No findings" : "\(findings) finding\(findings == 1 ? "" : "s")"
        case .failed(let reason): reason
        case .cancelled: "Stopped"
        }
    }
}
