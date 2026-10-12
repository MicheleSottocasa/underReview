import AppKit
import Observation
import ReviewDeskCore

struct RecentEvent: Identifiable {
    let id = UUID()
    let pr: PullRequest
    let kinds: [UpdateKind]
    let date = Date()
}

enum SidebarSelection: Hashable {
    case inbox, all
    case folder(UUID)
}

@Observable @MainActor
final class AppModel {
    var viewer = ""
    var setupError: String?
    var lastError: String?
    var isRefreshing = false

    /// Every PR we track, by node id.
    var prs: [String: PullRequest] = [:]
    var inboxIDs: Set<String> = []
    var details: [String: PRDetail] = [:]
    /// Changed files per PR, fetched on demand and kept in memory only.
    var files: [String: [FileChange]] = [:]

    var sidebar: SidebarSelection = .inbox
    var selectedPRID: String?

    var org: Organization { didSet { save(orgFile, org) } }
    var checkpoints: [String: Snapshot]
    var reviewDrafts: ReviewDrafts { didSet { save(draftsFile, reviewDrafts) } }
    var recentEvents: [RecentEvent] = []
    var aiRuns: [AIRun] { didSet { save(aiRunsFile, aiRuns) } }
    /// PR id → what the AI is doing right now.
    var aiStatus: [String: String] = [:]
    var aiTasks: [String: Task<Void, Never>] = [:]

    let notifier = Notifier()
    /// Captured from SwiftUI so notifications and the menu bar can reopen a closed window.
    var openMainWindow: (() -> Void)?

    static let tools = ["gh", "claude", "codex", "ollama"]
    /// Where each CLI was found at launch.
    let toolPaths: [String: String]
    let github: GitHub
    let reviewer: AIReviewer
    private let orgFile = JSONFile<Organization>.appSupport("organization.json")
    private let checkpointFile = JSONFile<[String: Snapshot]>.appSupport("checkpoints.json")
    private let draftsFile = JSONFile<ReviewDrafts>.appSupport("drafts.json")
    private let aiRunsFile = JSONFile<[AIRun]>.appSupport("ai-runs.json")
    private var pollTask: Task<Void, Never>?

    init() {
        let overrides = Self.tools.reduce(into: [String: String]()) { $0[$1] = UserDefaults.standard.string(forKey: "path.\($1)") }
        let runner = ProcessRunner(paths: ProcessRunner.discover(Self.tools, overrides: overrides))
        toolPaths = runner.paths
        github = GitHub(runner: runner)
        org = orgFile.load(default: Organization())
        checkpoints = checkpointFile.load(default: [:])
        reviewDrafts = draftsFile.load(default: ReviewDrafts())
        aiRuns = aiRunsFile.load(default: [])
        reviewer = AIReviewer(runner: runner)
    }

    var selectedPR: PullRequest? { selectedPRID.flatMap { prs[$0] } }

    func items(for selection: SidebarSelection) -> [Item] {
        let all = Stacks.items(Array(prs.values))
        switch selection {
        case .all: return all
        case .inbox: return all.filter { org.placements[$0.key] == nil }
        case .folder(let id): return all.filter { org.placements[$0.key] == id }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard pollTask == nil else { return }
        notifier.onOpen = { [weak self] id in self?.open(prID: id) }
        notifier.setUp()
        pollTask = Task {
            do {
                viewer = try await github.viewerLogin()
                setupError = nil
            } catch {
                setupError = error.localizedDescription
                pollTask = nil
                return
            }
            var failures = 0
            while !Task.isCancelled {
                do {
                    try await refresh()
                    failures = 0
                } catch {
                    failures += 1
                    lastError = error.localizedDescription
                }
                try? await Task.sleep(for: Updates.interval(foreground: NSApp.isActive, failures: failures))
            }
        }
    }

    func retrySetup() {
        pollTask?.cancel()
        pollTask = nil
        start()
    }

    func refresh() async throws {
        isRefreshing = true
        defer { isRefreshing = false }
        let inbox = try await github.inbox()
        inboxIDs = Set(inbox.map(\.id))
        var fresh = Dictionary(inbox.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let others = org.followed.keys.filter { fresh[$0] == nil }
        for pr in try await github.pullRequests(ids: Array(others)) { fresh[pr.id] = pr }
        for pr in try await github.pullRequests(ids: Stacks.missingMembers(of: Array(fresh.values)).filter { !org.unfollowed.contains($0) }) { fresh[pr.id] = pr }

        // ponytail: everything seen is followed until the user stops monitoring it, so merges and closes
        // still notify. Merged PRs keep being polled; auto-archive them if the list grows too long.
        var updated = org
        for pr in fresh.values where updated.followed[pr.id] == nil && !updated.unfollowed.contains(pr.id) {
            updated.follow(id: pr.id, url: pr.url)
        }
        if updated != org { org = updated }
        prs = fresh.filter { !org.unfollowed.contains($0.key) }
        lastError = nil
        await didRefresh(Array(prs.values))
        save(checkpointFile, checkpoints)
        if let id = selectedPRID, prs[id] != nil { await loadDetail(id) }
    }

    /// Hook for later features (notifications, stale drafts).
    func didRefresh(_ prs: [PullRequest]) async {
        let events = Updates.advance(&checkpoints, with: prs, viewer: viewer)
        for (id, kinds) in events {
            guard let pr = self.prs[id] else { continue }
            recentEvents.insert(RecentEvent(pr: pr, kinds: kinds), at: 0)
            if !org.muted.contains(pr.itemKey) { notifier.post(pr, kinds: kinds) }
        }
        recentEvents = Array(recentEvents.prefix(20))
        await refreshStaleDrafts(prs)
    }

    func open(prID: String) {
        guard prs[prID] != nil else { return }
        selectedPRID = prID
        if let item = items(for: .all).first(where: { $0.pullRequests.contains { $0.id == prID } }) {
            sidebar = org.placements[item.key].map(SidebarSelection.folder) ?? .inbox
        }
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleMute(_ item: Item) {
        if org.muted.contains(item.key) { org.muted.remove(item.key) } else { org.muted.insert(item.key) }
    }

    func refreshNow() {
        Task {
            do { try await refresh() } catch { lastError = error.localizedDescription }
        }
    }

    // MARK: Actions

    func addPR(_ text: String) async throws {
        guard let ref = PRRef(text) else { throw GitHubError.notFound("Pull request link “\(text)”") }
        let pr = try await github.pullRequest(ref)
        org.follow(id: pr.id, url: pr.url)
        prs[pr.id] = pr
        selectedPRID = pr.id
        try await refresh()
    }

    /// Moving a stack moves all its PRs: placement is keyed by the stack.
    func move(_ itemKey: String, to folder: UUID?) {
        org.place(itemKey, in: folder)
    }

    func deleteFolder(_ id: UUID) {
        org.deleteFolder(id)
        if case .folder(let selected) = sidebar, !org.folders.contains(where: { $0.id == selected }) { sidebar = .inbox }
    }

    func stopMonitoring(_ item: Item) {
        for pr in item.pullRequests {
            org.unfollow(id: pr.id)
            prs[pr.id] = nil
        }
        if item.pullRequests.contains(where: { $0.id == selectedPRID }) { selectedPRID = nil }
    }

    func loadDetail(_ id: String) async {
        do {
            details[id] = try await github.detail(id: id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openOnGitHub(_ pr: PullRequest) {
        if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
    }

    func save<T: Codable>(_ file: JSONFile<T>, _ value: T) {
        do { try file.save(value) } catch { lastError = "Couldn't save \(file.url.lastPathComponent): \(error.localizedDescription)" }
    }
}
