import ReviewDeskCore
import SwiftUI

struct AIView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    @AppStorage("aiEngine") private var engineName = "claude"
    @AppStorage("ollamaModel") private var ollamaModel = "qwen2.5-coder"
    @AppStorage("aiBudget") private var budget = 150_000
    @ViewState private var context: ReviewContext?
    @ViewState private var preparing = false

    private var engine: AIEngine {
        switch engineName {
        case "linked" where model.agentLinks[pr.id] != nil: model.agentLinks[pr.id]!.engine
        case "codex": .codex
        case "ollama": .ollama(model: ollamaModel)
        default: .claudeCode
        }
    }

    var body: some View {
        let status = model.aiStatus[pr.id]
        let runs = model.runs(for: pr.id)
        VStack(spacing: 0) {
            toolbar(status: status)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LinkedAgentCard(pr: pr) {
                        engineName = "linked"
                        prepare()
                    }
                    if let status {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(status)
                            Spacer()
                            Button("Cancel") { model.cancelReview(pr.id) }
                        }
                        .padding(10)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let context {
                        ContextPanel(context: Binding(get: { context }, set: { self.context = $0 }), engine: engine) {
                            model.startReview(pr, engine: engine, context: context)
                            self.context = nil
                        }
                    }
                    ForEach(runs) { RunView(pr: pr, run: $0) }
                    if runs.isEmpty && context == nil && status == nil {
                        ContentUnavailableView {
                            Label("No AI reviews yet", systemImage: "sparkles")
                        } description: {
                            Text("Prepare the context to see exactly what will be sent, then run the review. Findings stay here until you add them to your review.")
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

    private func toolbar(status: String?) -> some View {
        HStack(spacing: 10) {
            Picker("Engine", selection: $engineName) {
                if let link = model.agentLinks[pr.id] { Text("Linked: \(link.name)").tag("linked") }
                Text("Claude Code").tag("claude")
                Text("Codex").tag("codex")
                Text("Ollama (local)").tag("ollama")
            }
            .fixedSize()
            if engineName == "ollama" {
                TextField("Model", text: $ollamaModel).frame(width: 140)
            }
            LabeledContent("Budget") {
                TextField("", value: $budget, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
            }
            .fixedSize()
            if !engine.isLocal {
                Image(systemName: "icloud.and.arrow.up").foregroundStyle(.orange)
                    .help("The selected code is sent to \(engine.name)'s provider using your CLI login.")
            }
            Spacer()
            if let stack = model.allItems.first(where: { $0.key == pr.itemKey && $0.isStack }) {
                Button("Review Stack (\(stack.pullRequests.count))") {
                    model.startStackReview(stack.pullRequests.filter { $0.state == "OPEN" }, engine: engine, budget: budget, from: pr.id)
                }
                .disabled(status != nil)
                .help("One review per open PR, bottom of the stack first")
            }
            Button(preparing ? "Preparing…" : "Prepare Context") { prepare() }
                .buttonStyle(.borderedProminent)
                .disabled(preparing || status != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
                Text(run.date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                if outdated { Badge(text: "Outdated by push", color: .orange) }
                Spacer()
                Button("Delete") { model.deleteRun(run.id) }.buttonStyle(.link)
            }
            .font(.callout)
            MarkdownText(run.result.summary)
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
            Text(finding.rationale).font(.callout).foregroundStyle(.secondary)
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

/// Searchable list of running sessions: ones named after the PR or in its repo first.
struct AgentPicker: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let choose: (RunningAgent) -> Void
    let cancel: () -> Void
    @ViewState private var query = ""
    @ViewState private var selection: String?

    var body: some View {
        let agents = ClaudeAgents.sorted(model.runningAgents, for: pr.ref).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query)
        }
        let suggested = agents.filter { ClaudeAgents.relevance($0, to: pr.ref) > 0 }
        let other = agents.filter { ClaudeAgents.relevance($0, to: pr.ref) == 0 }
        VStack(alignment: .leading, spacing: 10) {
            Text("Link a Claude Code agent").font(.headline)
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
                if !suggested.isEmpty {
                    Section("Suggested") { ForEach(suggested) { row($0) } }
                }
                if !other.isEmpty {
                    Section("Other") { ForEach(other) { row($0) } }
                }
            }
            .listStyle(.inset)
            .overlay {
                if agents.isEmpty {
                    ContentUnavailableView("No running agents", systemImage: "apple.terminal",
                                           description: Text("Start a session with `claude` or `claude --bg`, then refresh."))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Link") {
                    if let agent = model.runningAgents.first(where: { $0.id == selection }) { choose(agent) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 520, height: 440)
        .task { await model.refreshAgents() }
    }

    private func row(_ agent: RunningAgent) -> some View {
        HStack(spacing: 10) {
            AgentStatus(status: agent.status, compact: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).lineLimit(1)
                Text(agent.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(agent.isBackground ? "background" : "terminal").font(.caption).foregroundStyle(.secondary)
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
