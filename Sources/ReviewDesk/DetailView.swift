import ReviewDeskCore
import SwiftUI

enum DetailTab: String, CaseIterable {
    case overview = "Overview", files = "Files", review = "Review", ai = "AI", notes = "Notes"
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    @ViewState private var tab = DetailTab.overview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding()
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            Divider().padding(.top, 8)
            switch tab {
            case .overview: OverviewView(pr: pr, detail: model.details[pr.id])
            case .files: FilesView(pr: pr)
            case .review: ReviewView(pr: pr)
            case .ai: AIView(pr: pr)
            case .notes: NotesView(pr: pr)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(pr.title).font(.title2.bold()).textSelection(.enabled)
                Spacer()
                Button("Open on GitHub") { model.openOnGitHub(pr) }
            }
            HStack(spacing: 8) {
                StateBadge(pr: pr)
                Text("\(pr.repo)#\(pr.number) by \(pr.author)")
                Text("\(pr.headRefName) → \(pr.baseRefName)").font(.caption.monospaced())
                if let position = pr.stackPosition, let stack = pr.stack {
                    Text("Stack #\(stack.number): \(position) of \(stack.entries.count)")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

struct OverviewView: View {
    let pr: PullRequest
    let detail: PRDetail?

    var body: some View {
        if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MarkdownText(detail.body.isEmpty ? "_No description._" : detail.body)
                    if !timeline(detail).isEmpty {
                        Divider()
                        Text("Conversation").font(.headline)
                        ForEach(timeline(detail), id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(entry.author) · \(entry.label) · \(entry.date.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !entry.body.isEmpty { MarkdownText(entry.body) }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct Entry {
        var id: String, author: String, label: String, body: String, date: Date
    }

    private func timeline(_ detail: PRDetail) -> [Entry] {
        let comments = detail.comments.map { Entry(id: $0.id, author: $0.author, label: "commented", body: $0.body, date: $0.createdAt) }
        let reviews = detail.reviews.map {
            Entry(id: $0.id, author: $0.author, label: $0.state.lowercased().replacingOccurrences(of: "_", with: " "), body: $0.body, date: $0.submittedAt ?? .distantPast)
        }
        return (comments + reviews).sorted { $0.date < $1.date }
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

/// GitHub Markdown rendered with Foundation's parser (inline styles, links, line breaks).
struct MarkdownText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        Text((try? AttributedString(markdown: source, options: options)) ?? AttributedString(source))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
