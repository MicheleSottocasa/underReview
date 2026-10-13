import Foundation
import ReviewDeskCore

extension AppModel {
    func runs(for prID: String) -> [AIRun] {
        aiRuns.filter { $0.prID == prID }.sorted { $0.date > $1.date }
    }

    /// Diff plus full files at head. Nothing is sent anywhere until the user runs the review.
    func prepareContext(_ pr: PullRequest, budget: Int) async throws -> ReviewContext {
        if files[pr.id] == nil { files[pr.id] = try await github.files(pr.ref) }
        if details[pr.id] == nil { await loadDetail(pr.id) }
        let changed = files[pr.id] ?? []
        let paths = changed.filter { $0.status != "removed" && $0.patch != nil }.map(\.filename)
        let contents = try await github.fileContents(repo: pr.repo, paths: paths, ref: pr.headRefOid)
        return AIContext.build(pr: pr, body: details[pr.id]?.body ?? "", files: changed, contents: contents, budget: budget,
                               rules: await repoRules(pr, changed: changed))
    }

    /// The repository's rule files on the PR's base branch: the rules the change has to follow. A failed fetch
    /// just means a review without them; it shouldn't block the review.
    func repoRules(_ pr: PullRequest, changed: [FileChange]) async -> [String: String] {
        (try? await github.fileContents(repo: pr.repo, paths: RepoRules.candidates(changed: changed.map(\.filename)), ref: pr.baseRefName)) ?? [:]
    }

    func startReview(_ pr: PullRequest, engine: AIEngine, context: ReviewContext) {
        aiTasks[pr.id]?.cancel()
        aiTasks[pr.id] = Task {
            await review(pr, engine: engine, context: context)
            aiTasks[pr.id] = nil
        }
    }

    /// Claude Code's `/code-review` on the PR, with the chosen model and effort.
    func startCodeReview(_ pr: PullRequest, engine: AIEngine, options: CodeReviewOptions) {
        aiTasks[pr.id]?.cancel()
        aiTasks[pr.id] = Task {
            await codeReview(pr, engine: engine, options: options)
            aiTasks[pr.id] = nil
        }
    }

    /// One review per PR, bottom of the stack first: `/code-review` for Claude Code, otherwise the full default context.
    func startStackReview(_ prs: [PullRequest], engine: AIEngine, budget: Int, options: CodeReviewOptions, from current: String) {
        aiTasks[current]?.cancel()
        aiTasks[current] = Task {
            for pr in prs where !Task.isCancelled {
                if engine.tool == "claude" {
                    aiStatus[current] = "Running /code-review on #\(pr.number)…"
                    await codeReview(pr, engine: engine, options: options)
                    continue
                }
                do {
                    aiStatus[current] = "Preparing #\(pr.number)…"
                    let context = try await prepareContext(pr, budget: budget)
                    guard context.fitsBudget else {
                        lastError = "#\(pr.number) is over the token budget; review it on its own and deselect files."
                        continue
                    }
                    aiStatus[current] = "Reviewing #\(pr.number) with \(engine.name)…"
                    await review(pr, engine: engine, context: context)
                } catch {
                    lastError = error.localizedDescription
                }
            }
            aiStatus[current] = nil
            aiTasks[current] = nil
        }
    }

    func cancelReview(_ prID: String) {
        aiTasks[prID]?.cancel()
        aiTasks[prID] = nil
        aiStatus[prID] = nil
        aiActivity[prID] = nil
    }

    /// Adds a step to the live log, skipping repeats (the helper agent's text is forwarded twice).
    func logStep(_ text: String, pr prID: String) {
        var steps = aiActivity[prID] ?? []
        guard steps.last?.text != text else { return }
        steps.append(AIStep(text: text))
        aiActivity[prID] = Array(steps.suffix(40))
    }

    private func codeReview(_ pr: PullRequest, engine: AIEngine, options: CodeReviewOptions) async {
        aiStatus[pr.id] = "Running /code-review (\(options.effort)) with \(engine.name)…"
        aiActivity[pr.id] = []
        defer {
            aiStatus[pr.id] = nil
            aiActivity[pr.id] = nil
        }
        do {
            if files[pr.id] == nil { files[pr.id] = try await github.files(pr.ref) }
            if details[pr.id] == nil { await loadDetail(pr.id) }
            // Diffs only: they let the second pass pick key areas; /code-review fetches the PR itself.
            let changed = files[pr.id] ?? []
            aiStatus[pr.id] = "Reading the repository's rules…"
            let rules = await repoRules(pr, changed: changed)
            logStep(rules.isEmpty ? "No repository rules found (AGENTS.md, CONTRIBUTING.md…)"
                                  : "Repository rules: " + RepoRules.candidates(changed: changed.map(\.filename)).filter { rules[$0] != nil }.joined(separator: ", "),
                    pr: pr.id)
            aiStatus[pr.id] = "Running /code-review (\(options.effort)) with \(engine.name)…"
            let context = AIContext.build(pr: pr, body: details[pr.id]?.body ?? "", files: changed, contents: [:],
                                          budget: UserDefaults.standard.object(forKey: "aiBudget") as? Int ?? 150_000, rules: rules)
            let result = try await reviewer.codeReview(engine, prURL: pr.url, context: context, options: options,
                                                       instructions: Prompts.codeReview, structureInstructions: Prompts.structure) { step in
                Task { @MainActor in self.logStep(step, pr: pr.id) }
            }
            var run = AIRun(prID: pr.id, engine: engine, headRefOid: pr.headRefOid, result: result)
            run.options = options
            aiRuns.append(run)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { lastError = "\(engine.name): \(error.localizedDescription)" }
        }
    }

    private func review(_ pr: PullRequest, engine: AIEngine, context: ReviewContext) async {
        aiStatus[pr.id] = "Reviewing with \(engine.name)…"
        defer { aiStatus[pr.id] = nil }
        do {
            let result = try await reviewer.review(engine, prompt: AIContext.prompt(context, instructions: Prompts.review))
            aiRuns.append(AIRun(prID: pr.id, engine: engine, headRefOid: pr.headRefOid, result: result))
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { lastError = "\(engine.name): \(error.localizedDescription)" }
        }
    }

    /// Inline findings become local drafts; general ones go into the review body. Nothing is posted.
    func accept(_ runID: UUID, finding index: Int) {
        guard let runIndex = aiRuns.firstIndex(where: { $0.id == runID }), let pr = prs[aiRuns[runIndex].prID] else { return }
        let finding = aiRuns[runIndex].result.findings[index]
        let (inline, _) = AIContext.validate(ReviewResult(summary: "", findings: [finding]), files: files[pr.id] ?? [])
        if let anchor = inline.first?.anchor, aiRuns[runIndex].headRefOid == pr.headRefOid {
            addDraft(pr, anchor: anchor, body: finding.comment)
        } else {
            let body = reviewDrafts.bodies[pr.id].map { $0 + "\n\n" } ?? ""
            reviewDrafts.bodies[pr.id] = body + finding.comment
        }
        aiRuns[runIndex].handled.insert(index)
    }

    func dismiss(_ runID: UUID, finding index: Int) {
        guard let runIndex = aiRuns.firstIndex(where: { $0.id == runID }) else { return }
        aiRuns[runIndex].handled.insert(index)
    }

    func deleteRun(_ runID: UUID) {
        aiRuns.removeAll { $0.id == runID }
    }

    func engine(named name: String, ollamaModel: String, for pr: PullRequest) -> AIEngine {
        switch name {
        case "linked" where agentLinks[pr.id] != nil: agentLinks[pr.id]!.engine
        case "codex": .codex
        case "ollama": .ollama(model: ollamaModel)
        default: .claudeCode
        }
    }

    /// The engine picked in the AI tab, so every AI action uses the same one.
    func preferredEngine(for pr: PullRequest) -> AIEngine {
        let defaults = UserDefaults.standard
        return engine(named: defaults.string(forKey: "aiEngine") ?? "claude",
                      ollamaModel: defaults.string(forKey: "ollamaModel") ?? "qwen2.5-coder", for: pr)
    }

    /// Asks the AI what a comment means. Sends the PR description, the conversation and, for inline
    /// comments, that file's diff to the engine's provider (nothing leaves the Mac with Ollama).
    func explain(_ comment: Comment, thread: ReviewThread?, pr: PullRequest) {
        let engine = preferredEngine(for: pr)
        explanations[comment.id] = Explanation(engine: engine.name)
        Task {
            do {
                if thread != nil, files[pr.id] == nil { files[pr.id] = try await github.files(pr.ref) }
                let conversation = thread?.comments ?? Array((details[pr.id]?.comments ?? []).prefix { $0.id != comment.id }.suffix(10) + [comment])
                let prompt = AIContext.explainPrompt(
                    title: pr.title, body: details[pr.id]?.body ?? "", path: thread?.path, line: thread?.line,
                    patch: thread.flatMap { thread in files[pr.id]?.first { $0.filename == thread.path }?.patch },
                    conversation: conversation, comment: comment, instructions: Prompts.explain)
                explanations[comment.id]?.text = try await reviewer.ask(engine, prompt: prompt)
            } catch {
                explanations[comment.id] = nil
                lastError = "\(engine.name): \(error.localizedDescription)"
            }
        }
    }
}

struct Explanation {
    var engine: String
    /// Nil while the engine is still answering.
    var text: String?
}

/// The AI prompts, as customized in Settings. An empty override means the built-in default.
enum Prompts {
    static let reviewKey = "prompt.review", codeReviewKey = "prompt.codeReview", structureKey = "prompt.structure"
    static let explainKey = "prompt.explain"

    static var review: String { value(reviewKey, AIContext.defaultReviewInstructions) }
    static var codeReview: String { value(codeReviewKey, AIContext.defaultCodeReviewInstructions) }
    static var structure: String { value(structureKey, AIContext.defaultStructureInstructions) }
    static var explain: String { value(explainKey, AIContext.defaultExplainInstructions) }

    private static func value(_ key: String, _ fallback: String) -> String {
        let custom = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? fallback : custom
    }
}

/// One line of a running review's live log.
struct AIStep: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date = Date()
}
