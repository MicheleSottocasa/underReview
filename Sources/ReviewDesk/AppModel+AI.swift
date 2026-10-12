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
        let github = github
        let contents = await withTaskGroup(of: (String, String?).self) { group in
            for file in changed where file.status != "removed" && file.patch != nil {
                group.addTask { (file.filename, try? await github.fileContent(repo: pr.repo, path: file.filename, ref: pr.headRefOid)) }
            }
            var result: [String: String] = [:]
            for await (path, content) in group { result[path] = content }
            return result
        }
        return AIContext.build(pr: pr, body: details[pr.id]?.body ?? "", files: changed, contents: contents, budget: budget)
    }

    func startReview(_ pr: PullRequest, engine: AIEngine, context: ReviewContext) {
        aiTasks[pr.id]?.cancel()
        aiTasks[pr.id] = Task {
            await review(pr, engine: engine, context: context)
            aiTasks[pr.id] = nil
        }
    }

    /// One review per PR, bottom of the stack first, each with its full default context.
    func startStackReview(_ prs: [PullRequest], engine: AIEngine, budget: Int, from current: String) {
        aiTasks[current]?.cancel()
        aiTasks[current] = Task {
            for pr in prs where !Task.isCancelled {
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
    }

    private func review(_ pr: PullRequest, engine: AIEngine, context: ReviewContext) async {
        aiStatus[pr.id] = "Reviewing with \(engine.name)…"
        defer { aiStatus[pr.id] = nil }
        do {
            let result = try await reviewer.review(engine, prompt: AIContext.prompt(context))
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
}
