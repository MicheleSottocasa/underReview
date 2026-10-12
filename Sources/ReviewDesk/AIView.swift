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
        case "codex": .codex
        case "ollama": .ollama(model: ollamaModel)
        default: .claudeCode
        }
    }

    var body: some View {
        let status = model.aiStatus[pr.id]
        Form {
            Section("Engine") {
                Picker("Run with", selection: $engineName) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                    Text("Ollama (local)").tag("ollama")
                }
                if engineName == "ollama" { TextField("Ollama model", text: $ollamaModel) }
                TextField("Token budget", value: $budget, format: .number)
                if !engine.isLocal {
                    Label("The selected code is sent to \(engine.name)'s provider using your CLI login.", systemImage: "icloud.and.arrow.up")
                        .foregroundStyle(.orange)
                }
            }

            Section("Context") {
                if let context {
                    ContextEditor(context: Binding(get: { context }, set: { self.context = $0 }))
                    Button("Run Review") { model.startReview(pr, engine: engine, context: context) }
                        .disabled(!context.fitsBudget || status != nil)
                } else {
                    Button(preparing ? "Preparing…" : "Prepare Context") { prepare() }.disabled(preparing)
                }
                if let stack = model.items(for: .all).first(where: { $0.key == pr.itemKey && $0.isStack }) {
                    Button("Review Whole Stack (\(stack.pullRequests.count) PRs, bottom first)") {
                        model.startStackReview(stack.pullRequests.filter { $0.state == "OPEN" }, engine: engine, budget: budget, from: pr.id)
                    }
                    .disabled(status != nil)
                }
                if let status {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(status)
                        Spacer()
                        Button("Cancel") { model.cancelReview(pr.id) }
                    }
                }
            }

            ForEach(model.runs(for: pr.id)) { run in
                RunSection(pr: pr, run: run)
            }
        }
        .formStyle(.grouped)
        .onChange(of: budget) { _, value in context?.budget = value }
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
struct ContextEditor: View {
    @Binding var context: ReviewContext

    var body: some View {
        ForEach($context.files) { $file in
            HStack {
                Toggle(isOn: $file.included) { Text(file.path).font(.callout.monospaced()) }
                    .disabled(file.excludedReason != nil)
                Spacer()
                if let reason = file.excludedReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else {
                    if file.content == nil { Text("diff only").font(.caption).foregroundStyle(.secondary) }
                    Text("\(file.tokens.formatted()) tok").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        LabeledContent("Estimated size") {
            Text("\(context.tokens.formatted()) / \(context.budget.formatted()) tokens")
                .foregroundStyle(context.fitsBudget ? Color.secondary : Color.red)
        }
        if !context.fitsBudget {
            Text("Over budget: deselect files or raise the budget. Nothing is truncated automatically.").foregroundStyle(.red)
        }
        Text("Submodules and Git LFS content are not fetched.").font(.caption).foregroundStyle(.secondary)
    }
}

struct RunSection: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let run: AIRun

    var body: some View {
        let outdated = run.headRefOid != pr.headRefOid
        let (inline, _) = AIContext.validate(run.result, files: model.files[pr.id] ?? [])
        Section {
            MarkdownText(run.result.summary)
            if outdated {
                Label("Outdated: new commits were pushed after this review. Findings can only go into the review body.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(Array(run.result.findings.enumerated()), id: \.offset) { index, finding in
                let isInline = !outdated && inline.contains(finding)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(finding.severity.uppercased()).font(.caption.bold()).foregroundStyle(color(finding.severity))
                        Text(finding.title).bold()
                        Spacer()
                        Text(isInline ? "\(finding.path ?? ""):\(finding.line ?? 0)" : "General").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(finding.rationale).font(.callout).foregroundStyle(.secondary)
                    MarkdownText(finding.comment)
                    if !run.handled.contains(index) {
                        HStack {
                            Button(isInline ? "Add as Draft" : "Add to Review Body") { model.accept(run.id, finding: index) }
                            Button("Dismiss") { model.dismiss(run.id, finding: index) }
                        }
                    }
                }
                .opacity(run.handled.contains(index) ? 0.45 : 1)
            }
        } header: {
            HStack {
                Text("\(run.engine.name) · \(run.date.formatted(date: .abbreviated, time: .shortened))")
                Spacer()
                Button("Delete") { model.deleteRun(run.id) }.buttonStyle(.link)
            }
        }
        .task { if model.files[pr.id] == nil { await model.loadFiles(pr) } }
    }

    private func color(_ severity: String) -> Color {
        switch severity {
        case "critical", "high": .red
        case "medium": .orange
        default: .secondary
        }
    }
}
