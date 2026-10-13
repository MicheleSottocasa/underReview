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
    /// The engine a Re-run asked for, when it differs from the toolbar's; nil runs with the toolbar's engine.
    @ViewState private var contextEngine: AIEngine?

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
                    if let latest = runs.first { OutdatedAnalysisBanner(pr: pr, run: latest) }
                    if let context {
                        let runEngine = contextEngine ?? engine
                        ContextPanel(context: Binding(get: { context }, set: { self.context = $0 }), engine: runEngine) {
                            model.startReview(pr, engine: runEngine, context: context)
                            self.context = nil
                            contextEngine = nil
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
        .onChange(of: model.contextRequest, initial: true) { _, request in
            // Re-run from a stale-analysis banner, with Codex or Ollama: show what will be sent, for the run's engine.
            guard let request, request.prID == pr.id else { return }
            model.contextRequest = nil
            prepare(for: request.engine)
        }
        .onChange(of: engineName) { contextEngine = nil }
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

    /// `override` is a Re-run's engine; nil means the toolbar's.
    private func prepare(for override: AIEngine? = nil) {
        contextEngine = override == engine ? nil : override
        preparing = true
        Task {
            do { context = try await model.prepareContext(pr, budget: budget) } catch { model.report(error) }
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
            if !context.extra.isEmpty {
                Divider()
                Text("Project context: reference material you attached to this project").font(.caption.bold()).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                ForEach($context.extra) { $file in
                    HStack {
                        Toggle(isOn: $file.included) { Text(file.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle) }
                            .disabled(file.excludedReason != nil)
                        Spacer()
                        if let reason = file.excludedReason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(file.tokens.formatted())").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                        }
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
        let changed = model.files[pr.id] ?? []
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
                            + Text(inlineMarkdown(area.reason, repo: pr.repo)).font(.caption))
                    }
                }
                .padding(10)
                .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(Array(run.result.findings.enumerated()), id: \.offset) { index, finding in
                findingRow(index, finding, changed: changed)
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.25)))
        .task { if model.files[pr.id] == nil { await model.loadFiles(pr) } }
    }

    /// A finding, then the fix the AI proposes for it, if asked.
    @ViewBuilder
    private func findingRow(_ index: Int, _ finding: Finding, changed: [FileChange]) -> some View {
        let key = "\(run.id)#\(index)"
        FindingCard(finding: finding, files: changed, handled: run.handled.contains(index),
                    accept: { model.accept(run.id, finding: index, includeSuggestion: $0) },
                    dismiss: { model.dismiss(run.id, finding: index) },
                    fixing: model.fixes[key] != nil) {
            if let path = finding.path { model.suggestFix(key: key, problem: AIContext.fixProblem(finding), path: path, pr: pr) }
        }
        FixPreview(key: key, pr: pr) { model.dismiss(run.id, finding: index) }
    }
}

struct FindingCard: View {
    let finding: Finding
    let files: [FileChange]
    let handled: Bool
    let accept: (_ includeSuggestion: Bool) -> Void
    let dismiss: () -> Void
    @Environment(\.markdownRepo) private var repo
    /// A fix is being proposed or waits in its preview.
    var fixing = false
    var fix: () -> Void = {}
    @ViewState private var includeSuggestion = true

    private var placement: AIContext.Placement { AIContext.placement(finding, files: files, includeSuggestion: includeSuggestion) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Badge(text: finding.severity.uppercased(), color: color)
                Text(finding.title).bold()
                Spacer()
                Text(verbatim: location).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(inlineMarkdown(finding.rationale, repo: repo)).font(.callout).foregroundStyle(.secondary)
            MarkdownText(finding.comment).font(.callout)
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            if let suggestion = finding.suggestion {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle("Include the suggested change", isOn: $includeSuggestion)
                            .toggleStyle(.checkbox)
                            .disabled(handled)
                        Spacer()
                        Text(suggestionNote).font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(suggestion.isEmpty ? "(deletes the lines)" : suggestion)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.35)))
                    .opacity(includeSuggestion ? 1 : 0.4)
                }
            }
            if !handled {
                HStack {
                    Button(isInline ? "Add to Pending Review" : "Add to Review Summary") { accept(includeSuggestion) }
                        .help(isInline
                              ? "Adds it as an inline comment to your pending review on GitHub: only you see it until you submit the review"
                              : "Adds it to the summary of your review")
                    if finding.path != nil {
                        Button("Suggest Fix", action: fix)
                            .disabled(fixing)
                            .help("Asks the AI for replacement code you can edit, then add as a GitHub suggested change. Sends the PR description and this file's diff to the engine's provider (nothing leaves the Mac with Ollama).")
                    }
                    Button("Dismiss", action: dismiss).buttonStyle(.link)
                }
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.35)))
        .opacity(handled ? 0.5 : 1)
    }

    private var isInline: Bool { if case .inline = placement { true } else { false } }

    /// Where it will land: the lines it's placed on (and the one it meant, when GitHub can't comment there), or General.
    private var location: String {
        switch placement {
        case .inline(let anchor, let startLine, _):
            if let startLine { return "\(anchor.path):\(startLine)–\(anchor.line)" }
            return finding.line.map { $0 == anchor.line ? "\(anchor.path):\($0)" : "\(anchor.path):\(anchor.line) (about line \($0))" } ?? "\(anchor.path):\(anchor.line)"
        case .summary: return finding.path.map { "\($0) · Summary" } ?? "General"
        }
    }

    /// Whether GitHub will offer "Commit suggestion" for it, or it travels as plain code.
    private var suggestionNote: String {
        guard includeSuggestion else { return "Left out" }
        if case .inline(_, _, let body) = placement, body.contains("```suggestion") {
            return "GitHub suggested change: the author can apply it in one click"
        }
        return "Sent as plain code: its lines aren't all in the diff"
    }

    private var color: Color {
        switch finding.severity {
        case "critical", "high": .red
        case "medium": .orange
        default: .secondary
        }
    }
}

/// Shared by AI Review, Risk and Changes: the analysis they show is from an older head than the PR's.
struct OutdatedAnalysisBanner: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let run: AIRun

    var body: some View {
        if run.isOutdated(for: pr) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.outdatedMessage(for: pr, commits: model.commitsSince[AppModel.headPair(run, pr)] ?? nil))
                        .font(.callout.bold())
                    Text("Findings, risk answers and key areas may point at code that has changed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show Changes Since") { model.openChangesSince(run, pr: pr) }
                    .help("Opens GitHub's comparison of the analysed commit with the current head")
                Button("Re-run") { model.rerun(run, pr: pr) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isAIBusy(pr))
                    .help("Runs the analysis again with \(run.engine.name)\(run.options.map { ", \($0.model.isEmpty ? "default model" : $0.model.capitalized), \($0.effort) effort" } ?? "")")
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4)))
            .task(id: AppModel.headPair(run, pr)) { await model.loadCommitsSince(run, pr: pr) }
        }
    }
}

/// The AI's proposed fix for a finding or a comment: the lines it replaces and the editable replacement. Nothing is
/// posted until *Add to Pending Review*; *Discard* drops it.
struct FixPreview: View {
    @Environment(AppModel.self) private var model
    let key: String
    let pr: PullRequest
    var accepted: () -> Void = {}
    @ViewState private var code = ""
    @ViewState private var comment = ""

    var body: some View {
        if let fix = model.fixes[key] {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                    Text(fix.proposal == nil ? "Asking \(fix.engine.name) for a fix…" : "Suggested fix · \(fix.engine.name)")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    if fix.proposal == nil { ProgressView().controlSize(.small) }
                    Spacer()
                    if fix.proposal == nil {
                        Button("Discard") { model.discardFix(key) }.buttonStyle(.link).help("Stop asking for this fix")
                    }
                    if let proposal = fix.proposal, proposal.suggestion != nil {
                        Text(verbatim: "\(fix.path):\(lines(proposal))").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if let proposal = fix.proposal {
                    if proposal.suggestion == nil {
                        MarkdownText(proposal.comment).font(.callout)
                    } else {
                        if let current = fix.patch.flatMap({ AIContext.newSideText(patch: $0, from: proposal.startLine, to: proposal.line) }) {
                            codeBlock(current, color: .red).help("The lines it replaces, as they are now")
                        }
                        TextEditor(text: $code)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 60, maxHeight: 220)
                            .padding(4)
                            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.35)))
                            .help("The replacement: edit it before adding it to your review")
                        TextField("Comment posted with it", text: $comment, axis: .vertical).textFieldStyle(.roundedBorder)
                        Text(note(proposal, files: model.files[pr.id] ?? [])).font(.caption).foregroundStyle(.secondary)
                    }
                    let current = fix.isCurrent(for: model.prs[pr.id] ?? pr)
                    if !current {
                        Label(Fix.outdatedMessage, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        if proposal.suggestion != nil {
                            Button("Add to Pending Review") {
                                model.acceptFix(key, suggestion: code, comment: comment, pr: pr)
                                accepted()
                            }
                            .disabled(!current)
                            .help("Adds it to your pending review on GitHub as a suggested change: only you see it until you submit the review")
                        }
                        Button("Discard") { model.discardFix(key) }.buttonStyle(.link)
                    }
                }
            }
            .padding(10)
            .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.purple.opacity(0.3)))
            .onChange(of: fix.proposal, initial: true) { _, proposal in
                code = proposal?.suggestion ?? ""
                comment = proposal?.comment ?? ""
            }
        }
    }

    private func lines(_ proposal: FixProposal) -> String {
        proposal.startLine == proposal.line ? "\(proposal.line)" : "\(min(proposal.startLine, proposal.line))–\(max(proposal.startLine, proposal.line))"
    }

    private func codeBlock(_ text: String, color: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text.isEmpty ? " " : text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(8)
        }
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.3)))
    }

    /// Whether GitHub will offer "Commit suggestion", as for a finding's suggested change.
    private func note(_ proposal: FixProposal, files: [FileChange]) -> String {
        if case .inline(_, _, let body) = AIContext.placement(proposal.finding(path: fixPath), files: files),
           body.contains("```suggestion") {
            return "GitHub suggested change: the author can apply it in one click."
        }
        return "Sent as plain code in a comment: its lines aren't all in the diff, so GitHub can't apply it."
    }

    private var fixPath: String { model.fixes[key]?.path ?? "" }
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
                            if model.pending.contains(link.sessionID) { ProgressView().controlSize(.small) }
                            actions(running).disabled(model.pending.contains(link.sessionID))
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
                if model.pending.contains("agents") {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.refreshAgents() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh running agents")
                }
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
