import AppKit
import ReviewDeskCore
import SwiftUI

/// Risk-first review: the five questions in order, each with the author's Risk notes and the AI's key areas.
struct RiskView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        let run = model.keyAreasRun(for: pr)
        let areas = run?.result.keyAreas ?? []
        let notes = model.details[pr.id].flatMap { Risk.notes(in: $0.body) }
        let changed = model.files[pr.id]?.map(\.filename) ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                intro(run: run)
                notesCard(notes)
                ForEach(Array(RiskQuestion.allCases.enumerated()), id: \.element) { index, question in
                    QuestionCard(pr: pr, number: index + 1, question: question, assessment: run?.result.risk(question),
                                 notes: notes?.byQuestion[question] ?? [],
                                 areas: areas.filter { $0.question == question },
                                 unflaggedDataFiles: question == .data && run != nil && !areas.contains { $0.question == .data }
                                     ? Risk.dataFiles(changed) : [])
                }
                let others = areas.filter { $0.question == nil }
                if !others.isEmpty {
                    card {
                        Text("Other key areas").font(.headline)
                        ForEach(Array(others.enumerated()), id: \.offset) { _, area in AreaRow(pr: pr, area: area) }
                    }
                }
                Text("Formatting, naming and \"I'd have done it differently\" are left to linters and taste.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if model.files[pr.id] == nil { await model.loadFiles(pr) }
            if model.details[pr.id] == nil { await model.loadDetail(pr.id) }
        }
    }

    @ViewBuilder
    private func intro(run: AIRun?) -> some View {
        let checked = RiskQuestion.allCases.filter { model.riskCheck($0, pr: pr) == pr.headRefOid }.count
        let engine = model.preferredEngine(for: pr)
        let busy = model.isAIBusy(pr)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review risk, not lines").font(.title3.bold())
                Group {
                    if let run {
                        Text("Analysis by \(run.engine.name), \(run.date.formatted(.relative(presentation: .named)))")
                            + Text(run.headRefOid == pr.headRefOid ? "" : " · from an older commit, lines may have moved").foregroundColor(.orange)
                    } else {
                        Text("Let the AI answer each question and point at the code to read, then check them off yourself.")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(checked)/\(RiskQuestion.allCases.count) checked").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button(engine.tool == "claude" ? (run == nil ? "Run Risk Analysis" : "Run Again") : "Prepare in AI Tab…") {
                model.runRiskAnalysis(pr)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            .help(engine.tool == "claude"
                  ? "Runs /code-review with \(engine.name) and the last used model and effort"
                  : "\(engine.name) needs its context approved in the AI tab first")
        }
        AIProgress(pr: pr)
        if let run, let top = run.result.risks.max(by: { $0.rank < $1.rank }), top.rank > 0, let question = top.riskQuestion {
            Label("Highest risk: \(question.label) (\(top.level))", systemImage: "flame")
                .font(.callout.bold()).foregroundStyle(RiskBadge.color(top.level))
        }
    }

    @ViewBuilder
    private func notesCard(_ notes: RiskNotes?) -> some View {
        if let notes {
            if !notes.unsure.isEmpty {
                card(accent: .orange) {
                    Label("The author is unsure about", systemImage: "exclamationmark.bubble").font(.headline).foregroundStyle(.orange)
                    ForEach(notes.unsure, id: \.self) { Text("• " + $0).font(.callout) }
                    Text("Start here: it's where the author points you.").font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Author's risk notes") {
                MarkdownText(notes.markdown.isEmpty ? "_Empty_" : notes.markdown).font(.callout).padding(.top, 4)
            }
            .font(.callout)
        } else {
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No Risk notes in the description").font(.callout.bold())
                        Text("When authors answer the questions up front, reviews get faster and point at what they're unsure about.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy PR Template") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Risk.template, forType: .string)
                    }
                    .help("A Risk notes section for your pull request template")
                }
            }
        }
    }
}

private struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let number: Int
    let question: RiskQuestion
    let assessment: RiskAssessment?
    let notes: [String]
    let areas: [KeyArea]
    let unflaggedDataFiles: [String]

    var body: some View {
        let checkedAt = model.riskCheck(question, pr: pr)
        let stale = checkedAt != nil && checkedAt != pr.headRefOid
        card(accent: checkedAt == pr.headRefOid ? .green : nil) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(number). \(question.title)").font(.headline)
                if let assessment { RiskBadge(level: assessment.level) }
                Spacer()
                if stale { Badge(text: "Checked before the last push", color: .orange) }
                Toggle("Checked", isOn: Binding(get: { checkedAt == pr.headRefOid },
                                                set: { model.setRiskCheck(question, checked: $0, pr: pr) }))
                .toggleStyle(.checkbox)
            }
            if let assessment {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                    MarkdownText(assessment.answer).font(.callout)
                }
            }
            Text(question.guidance).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Author says").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(notes, id: \.self) { MarkdownText("• " + $0).font(.callout) }
                }
            }
            if !unflaggedDataFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Data-layer files changed, but the AI flagged no data risk", systemImage: "exclamationmark.triangle")
                        .font(.caption.bold()).foregroundStyle(.orange)
                    ForEach(unflaggedDataFiles, id: \.self) { path in
                        Button(path) { model.openInChanges(path, line: nil, pr: pr) }.buttonStyle(.link).font(.caption.monospaced())
                    }
                }
            }
            ForEach(Array(areas.enumerated()), id: \.offset) { _, area in AreaRow(pr: pr, area: area) }
            if areas.isEmpty && model.keyAreasRun(for: pr) != nil && unflaggedDataFiles.isEmpty {
                Text("No key areas for this question.").font(.caption).foregroundStyle(.tertiary)
            }
            if question == .explain {
                let asked = model.reviewDrafts.bodies[pr.id]?.contains(AppModel.explainRequest) == true
                Button(asked ? "Added to Your Review Summary" : "Ask the Author to Explain") { model.askAuthorToExplain(pr) }
                    .disabled(asked)
                    .help("Adds \"\(AppModel.explainRequest)\" to the summary posted with your review")
            }
        }
    }
}

/// The AI's risk level for a question.
struct RiskBadge: View {
    let level: String

    var body: some View {
        Badge(text: level == "none" ? "NOT TOUCHED" : "\(level.uppercased()) RISK", color: Self.color(level))
    }

    static func color(_ level: String) -> Color {
        switch level {
        case "high": .red
        case "medium": .orange
        case "low": .green
        default: .secondary
        }
    }
}

/// A key area: where it is and why, opening Changes at its lines.
private struct AreaRow: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let area: KeyArea

    var body: some View {
        Button { model.openInChanges(area.path, line: area.startLine, pr: pr) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(area.path) · \(FileTree.lines(area))").font(.caption.monospaced()).foregroundStyle(Color.accentColor)
                Text(inlineMarkdown(area.reason)).font(.callout).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in Changes")
    }
}

private func card<Content: View>(accent: Color? = nil, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8, content: content)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke((accent ?? .secondary).opacity(accent == nil ? 0.25 : 0.6)))
}
