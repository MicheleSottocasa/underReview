import AppKit
import ReviewDeskCore

extension AppModel {
    func runs(for prID: String) -> [AIRun] {
        aiRuns.filter { $0.prID == prID }.sorted { $0.date > $1.date }
    }

    /// The latest analysis of an open PR predates its head: the author pushed since.
    func hasOutdatedAnalysis(_ pr: PullRequest) -> Bool {
        pr.state == "OPEN" && runs(for: pr.id).first?.isOutdated(for: pr) == true
    }

    /// Counts the commits pushed since `run`, once per pair of heads. A failure or a diverged head (rebase,
    /// force-push) is cached too, as unknown, so the banner says "new commits" without asking GitHub again.
    func loadCommitsSince(_ run: AIRun, pr: PullRequest) async {
        let key = AppModel.headPair(run, pr)
        guard !pr.isDemo, commitsSince.index(forKey: key) == nil else { return }
        let count: Int? = try? await github.commitsAhead(repo: pr.repo, from: run.headRefOid, to: pr.headRefOid)
        commitsSince.updateValue(count, forKey: key) // a nil count is stored, not removed
    }

    /// The key of `commitsSince`: the analysed head and the current one.
    static func headPair(_ run: AIRun, _ pr: PullRequest) -> String { "\(run.headRefOid)..\(pr.headRefOid)" }

    /// Runs `run`'s analysis again on the current head, with the same engine (and model and effort, for /code-review).
    /// Codex and Ollama show their context in the AI tab first, as always.
    func rerun(_ run: AIRun, pr: PullRequest) {
        guard !blockDemo(pr) else { return }
        if run.engine.tool == "claude" {
            let defaults = UserDefaults.standard
            startCodeReview(pr, engine: run.engine, options: run.options ?? CodeReviewOptions(
                model: defaults.string(forKey: "claudeModel") ?? "", effort: defaults.string(forKey: "reviewEffort") ?? "high"))
            return
        }
        // The run's engine travels with the request: the AI tab's own engine choice stays as the user left it.
        detailTab = .ai
        contextRequest = ContextRequest(prID: pr.id, engine: run.engine)
    }

    /// GitHub's compare view between the analysed commit and the current head.
    func openChangesSince(_ run: AIRun, pr: PullRequest) {
        guard !blockDemo(pr), let url = GitHub.compareURL(repo: pr.repo, from: run.headRefOid, to: pr.headRefOid) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Diff plus full files at head. Nothing is sent anywhere until the user runs the review.
    func prepareContext(_ pr: PullRequest, budget: Int) async throws -> ReviewContext {
        if pr.isDemo { throw DemoError.readOnly }
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
        guard !blockDemo(pr) else { return }
        aiTasks[pr.id]?.cancel()
        aiTasks[pr.id] = Task {
            await review(pr, engine: engine, context: context)
            aiTasks[pr.id] = nil
        }
    }

    /// Claude Code's `/code-review` on the PR, with the chosen model and effort.
    /// Claude Code's `/code-review` on the PR, with the chosen model and effort.
    func startCodeReview(_ pr: PullRequest, engine: AIEngine, options: CodeReviewOptions) {
        guard !blockDemo(pr) else { return }
        aiTasks[pr.id]?.cancel()
        aiTasks[pr.id] = Task {
            aiActivity[pr.id] = []
            await codeReview(pr, engine: engine, options: options, key: pr.id)
            aiStatus[pr.id] = nil
            aiActivity[pr.id] = nil
            aiTasks[pr.id] = nil
        }
    }

    /// Reviews every PR of the stack with its own agent, several at once (Settings › AI), bottom of the stack first.
    /// Each PR's status and live steps stay on that PR; `current`, where it started, shows them all.
    func startStackReview(_ prs: [PullRequest], engine: AIEngine, budget: Int, options: CodeReviewOptions, from current: String) {
        if let demo = prs.first(where: \.isDemo) { _ = blockDemo(demo); return }
        guard !prs.isEmpty else { return }
        cancelStackRun(current)
        stackRuns[current] = StackRun(members: prs.map(\.id), states: Dictionary(uniqueKeysWithValues: prs.map { ($0.id, .waiting) }))
        for pr in prs {
            aiActivity[pr.id] = []
            aiStatus[pr.id] = "Waiting for a free agent…"
        }
        // ponytail: a fixed cap on parallel agents (Settings › AI); Ollama runs one at a time on this Mac.
        let limit = engine.isLocal ? 1 : max(1, UserDefaults.standard.object(forKey: "stackParallelAgents") as? Int ?? 3)
        aiTasks[current] = Task {
            // Cancelling the stack review cancels every agent; Cancel on a row cancels just that one.
            await Parallel.run(prs, limit: limit) { pr in
                let member = Task { await self.reviewStackMember(pr, engine: engine, budget: budget, options: options, run: current) }
                aiTasks[pr.id] = member
                return member
            }
            for pr in prs where stackRuns[current]?.states[pr.id] == .waiting {
                stackRuns[current]?.states[pr.id] = .cancelled
                aiStatus[pr.id] = nil
            }
            stackRuns[current]?.isFinished = true
            aiTasks[current] = nil
        }
    }

    /// One PR of a stack review, with its own agent; its state and log stay on the PR.
    private func reviewStackMember(_ pr: PullRequest, engine: AIEngine, budget: Int, options: CodeReviewOptions, run: String) async {
        guard !Task.isCancelled, stackRuns[run]?.states[pr.id] == .waiting else { return } // stopped before its turn
        stackRuns[run]?.states[pr.id] = .running
        let before = aiRuns.count, errorBefore = lastError
        if engine.tool == "claude" {
            await codeReview(pr, engine: engine, options: options, key: pr.id)
        } else {
            do {
                aiStatus[pr.id] = "Preparing the context…"
                let context = try await prepareContext(pr, budget: budget)
                if context.fitsBudget {
                    aiStatus[pr.id] = "Reviewing with \(engine.name)…"
                    await review(pr, engine: engine, context: context)
                } else {
                    stackRuns[run]?.states[pr.id] = .failed("Over the token budget: review it on its own and deselect files")
                }
            } catch {
                stackRuns[run]?.states[pr.id] = error.userMessage.map { .failed($0) } ?? .cancelled
            }
        }
        aiStatus[pr.id] = nil
        aiTasks[pr.id] = nil
        guard stackRuns[run]?.states[pr.id] == .running else { return }
        if Task.isCancelled {
            stackRuns[run]?.states[pr.id] = .cancelled
        } else if aiRuns.count > before, let result = aiRuns.last(where: { $0.prID == pr.id })?.result {
            stackRuns[run]?.states[pr.id] = .done(findings: result.findings.count)
        } else {
            stackRuns[run]?.states[pr.id] = .failed(lastError != errorBefore ? lastError ?? "No result" : "No result")
        }
    }

    /// The stack review this PR started or is part of, if any.
    func stackRun(for pr: PullRequest) -> (root: String, run: StackRun)? {
        if let run = stackRuns[pr.id] { return (pr.id, run) }
        return stackRuns.first { $0.value.members.contains(pr.id) }.map { ($0.key, $0.value) }
    }

    /// An AI run is going on for this PR: its own, or a stack review it's part of.
    func isAIBusy(_ pr: PullRequest) -> Bool {
        aiStatus[pr.id] != nil || stackRun(for: pr).map { !$0.run.isFinished } == true
    }

    /// Stops a stack review's agents, or hides a finished one together with its agents' logs.
    func cancelStackRun(_ root: String) {
        guard let run = stackRuns[root] else { return }
        if !run.isFinished {
            aiTasks[root]?.cancel()
            for id in run.members { aiTasks[id]?.cancel() }
            return
        }
        stackRuns[root] = nil
        for id in run.members where aiStatus[id] == nil { aiActivity[id] = nil }
    }

    func cancelReview(_ prID: String) {
        // A row of a stack review: stop only that agent (or skip it, if it hasn't started), keep its log in the list.
        if let root = stackRuns.first(where: { $0.value.members.contains(prID) && !$0.value.isFinished })?.key {
            if stackRuns[root]?.states[prID] == .waiting {
                stackRuns[root]?.states[prID] = .cancelled
                aiStatus[prID] = nil
            }
            aiTasks[prID]?.cancel()
            return
        }
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

    /// One PR's `/code-review`. Status and steps go to `key`, the PR whose progress box shows them (the one a
    /// stack review started from); the caller starts and clears that box. `label` names the PR in a stack run.
    private func codeReview(_ pr: PullRequest, engine: AIEngine, options: CodeReviewOptions, key: String, label: String? = nil) async {
        let on = label.map { " on \($0)" } ?? ""
        aiStatus[key] = "Running /code-review (\(options.effort))\(on) with \(engine.name)…"
        do {
            if files[pr.id] == nil { files[pr.id] = try await github.files(pr.ref) }
            if details[pr.id] == nil { await loadDetail(pr.id) }
            // Diffs only: they let the second pass pick key areas; /code-review fetches the PR itself.
            let changed = files[pr.id] ?? []
            aiStatus[key] = "Reading the repository's rules\(on)…"
            let rules = await repoRules(pr, changed: changed)
            logStep(rules.isEmpty ? "No repository rules found (AGENTS.md, CONTRIBUTING.md…)"
                                  : "Repository rules: " + RepoRules.candidates(changed: changed.map(\.filename)).filter { rules[$0] != nil }.joined(separator: ", "),
                    pr: key)
            aiStatus[key] = "Running /code-review (\(options.effort))\(on) with \(engine.name)…"
            let context = AIContext.build(pr: pr, body: details[pr.id]?.body ?? "", files: changed, contents: [:],
                                          budget: UserDefaults.standard.object(forKey: "aiBudget") as? Int ?? 150_000, rules: rules)
            let result = try await reviewer.codeReview(engine, prURL: pr.url, context: context, options: options,
                                                       instructions: Prompts.codeReview, structureInstructions: Prompts.structure) { step in
                Task { @MainActor in self.logStep(step, pr: key) }
            }
            var run = AIRun(prID: pr.id, engine: engine, headRefOid: pr.headRefOid, result: result)
            run.options = options
            aiRuns.append(run)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { report(error, engine.name) }
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
            if !Task.isCancelled { report(error, engine.name) }
        }
    }

    /// Inline findings become local drafts; general ones go into the review body. Nothing is posted.
    /// A finding about code goes straight into the viewer's pending review on GitHub, as an inline comment on its line
    /// (or the nearest commentable one, naming the line); general remarks go into the review summary. Pending stays
    /// visible only to the viewer until they submit the review.
    func accept(_ runID: UUID, finding index: Int, includeSuggestion: Bool = true) {
        guard let runIndex = aiRuns.firstIndex(where: { $0.id == runID }), let pr = prs[aiRuns[runIndex].prID] else { return }
        guard !blockDemo(pr) else { return }
        let finding = aiRuns[runIndex].result.findings[index]
        aiRuns[runIndex].handled.insert(index)
        Task {
            if files[pr.id] == nil { await loadFiles(pr) }
            switch AIContext.placement(finding, files: files[pr.id] ?? [], includeSuggestion: includeSuggestion) {
            case .inline(let anchor, let startLine, let body):
                let id = addDraft(pr, anchor: anchor, body: body, startLine: startLine)
                await saveDrafts([id], pr: pr)
            case .summary(let text):
                let body = reviewDrafts.bodies[pr.id].map { $0 + "\n\n" } ?? ""
                reviewDrafts.bodies[pr.id] = body + text
            }
        }
    }

    func dismiss(_ runID: UUID, finding index: Int) {
        guard let runIndex = aiRuns.firstIndex(where: { $0.id == runID }) else { return }
        aiRuns[runIndex].handled.insert(index)
    }

    func deleteRun(_ runID: UUID) {
        aiRuns.removeAll { $0.id == runID }
    }

    /// Asks a follow-up in a comment's Explain chat, with the same engine and context. Returns false if it failed,
    /// so the question can stay in the field.
    func askFollowUp(_ question: String, about commentID: String) async -> Bool {
        guard let chat = explanations[commentID], !chat.isAnswering, !chat.prompt.isEmpty else { return false }
        explanations[commentID]?.messages.append(ChatMessage(.reviewer, question))
        explanations[commentID]?.isAnswering = true
        defer { explanations[commentID]?.isAnswering = false }
        do {
            let prompt = AIContext.followUpPrompt(explainPrompt: chat.prompt, chat: chat.messages, question: question)
            let answer = try await reviewer.ask(chat.engine, prompt: prompt)
            explanations[commentID]?.messages.append(ChatMessage(.assistant, answer))
            return true
        } catch {
            if explanations[commentID]?.messages.last == ChatMessage(.reviewer, question) { explanations[commentID]?.messages.removeLast() }
            report(error, chat.engine.name)
            return false
        }
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

    /// Asks the AI what a comment means, then keeps the chat open for follow-ups. Sends the PR description, the
    /// conversation and, for inline comments, that file's diff to the engine's provider (nothing leaves the Mac with Ollama).
    func explain(_ comment: Comment, thread: ReviewThread?, pr: PullRequest) {
        guard !blockDemo(pr) else { return }
        let engine = preferredEngine(for: pr)
        explanations[comment.id] = Explanation(engine: engine)
        Task {
            do {
                let prompt = try await chatContext(comment, thread: thread, pr: pr)
                explanations[comment.id]?.prompt = prompt
                let answer = try await reviewer.ask(engine, prompt: prompt)
                explanations[comment.id]?.messages.append(ChatMessage(.assistant, answer))
                explanations[comment.id]?.isAnswering = false
            } catch {
                explanations[comment.id] = nil
                report(error, engine.name)
            }
        }
    }

    /// Opens the chat without an explanation first: the reviewer's own question is the first message.
    /// Same context as `explain`; nothing is sent until they ask.
    func openChat(_ comment: Comment, thread: ReviewThread?, pr: PullRequest) {
        guard !blockDemo(pr) else { return }
        guard explanations[comment.id] == nil else { return }
        let engine = preferredEngine(for: pr)
        explanations[comment.id] = Explanation(engine: engine)
        Task {
            do {
                explanations[comment.id]?.prompt = try await chatContext(comment, thread: thread, pr: pr)
                explanations[comment.id]?.isAnswering = false
            } catch {
                explanations[comment.id] = nil
                report(error)
            }
        }
    }

    /// The material both chats start from: PR description, the comment's conversation and its file's diff.
    private func chatContext(_ comment: Comment, thread: ReviewThread?, pr: PullRequest) async throws -> String {
        if thread != nil, files[pr.id] == nil { files[pr.id] = try await github.files(pr.ref) }
        let conversation = thread?.comments ?? Array((details[pr.id]?.comments ?? []).prefix { $0.id != comment.id }.suffix(10) + [comment])
        return AIContext.explainPrompt(
            title: pr.title, body: details[pr.id]?.body ?? "", path: thread?.path, line: thread?.line,
            patch: thread.flatMap { thread in files[pr.id]?.first { $0.filename == thread.path }?.patch },
            conversation: conversation, comment: comment, instructions: Prompts.explain)
    }
}

/// The Explain chat under a comment: the first answer, then the reviewer's follow-ups and their answers.
struct Explanation {
    var engine: AIEngine
    /// The first prompt (PR description, conversation, diff), resent with every follow-up so the context stays put.
    var prompt = ""
    var messages: [ChatMessage] = []
    var isAnswering = true
}

/// The AI prompts, as customized in Settings. An empty override means the built-in default.
enum Prompts {
    static let reviewKey = "prompt.review", codeReviewKey = "prompt.codeReview", structureKey = "prompt.structure"
    static let explainKey = "prompt.explain", followUpKey = "prompt.followUp"

    static var review: String { value(reviewKey, AIContext.defaultReviewInstructions) }
    static var codeReview: String { value(codeReviewKey, AIContext.defaultCodeReviewInstructions) }
    static var structure: String { value(structureKey, AIContext.defaultStructureInstructions) }
    static var explain: String { value(explainKey, AIContext.defaultExplainInstructions) }
    static var followUp: String { value(followUpKey, FollowUp.defaultInstructions) }

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

/// A stack review: one agent per PR, in stack order.
struct StackRun: Equatable {
    enum State: Equatable {
        case waiting, running, cancelled
        case done(findings: Int)
        case failed(String)
    }

    var members: [String]
    var states: [String: State]
    var isFinished = false
}
