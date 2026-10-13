import AppKit
import Observation
import ReviewDeskCore
import SwiftUI

struct RecentEvent: Identifiable {
    let id = UUID()
    let pr: PullRequest
    let kinds: [UpdateKind]
    let date = Date()
}

/// Sidebar state filter; Draft is an open PR marked as draft.
enum PRStateFilter: String, CaseIterable {
    case open, draft, merged, closed

    var title: String { rawValue.capitalized }

    func matches(_ pr: PullRequest) -> Bool {
        switch self {
        case .open: pr.state == "OPEN" && !pr.isDraft
        case .draft: pr.state == "OPEN" && pr.isDraft
        case .merged: pr.state == "MERGED"
        case .closed: pr.state == "CLOSED"
        }
    }
}

/// One row identity in the unified sidebar. Every PR appears exactly once, so tags never collide.
enum SidebarID: Hashable {
    case folder(UUID)
    case stack(String)
    case pr(String)
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
    /// Paths marked as viewed on GitHub, per PR. GitHub is the source of truth; nothing is stored locally.
    var viewedFiles: [String: Set<String>] = [:]

    /// Sidebar multi-selection. The detail follows the last single-selected PR and stays put otherwise.
    var selection: Set<SidebarID> = [] {
        didSet {
            guard selection.count == 1, case .pr(let id)? = selection.first, id != selectedPRID else { return }
            selectedPRID = id
            Task { await loadDetail(id) }
        }
    }
    var selectedPRID: String?
    var filter = ""
    /// States shown in the sidebar. Persisted; all by default.
    var stateFilter: Set<PRStateFilter> = Set((UserDefaults.standard.stringArray(forKey: "stateFilter") ?? PRStateFilter.allCases.map(\.rawValue)).compactMap(PRStateFilter.init)) {
        didSet { UserDefaults.standard.set(stateFilter.map(\.rawValue), forKey: "stateFilter") }
    }
    /// Expansion keys that differ from the default (folders open, stacks closed). Persisted.
    var toggledExpansion: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "toggledExpansion") ?? []) {
        didSet { UserDefaults.standard.set(Array(toggledExpansion), forKey: "toggledExpansion") }
    }
    var columns: NavigationSplitViewVisibility = .all
    /// Set when the Changes tab hid the sidebar, so leaving it only restores what the app hid.
    var sidebarAutoHidden = false

    var org: Organization { didSet { save(orgFile, org) } }
    var checkpoints: [String: Snapshot]
    var reviewDrafts: ReviewDrafts { didSet { save(draftsFile, reviewDrafts) } }
    var recentEvents: [RecentEvent] = []
    var aiRuns: [AIRun] { didSet { save(aiRunsFile, aiRuns) } }
    /// PR id → what the AI is doing right now.
    var aiStatus: [String: String] = [:]
    var aiTasks: [String: Task<Void, Never>] = [:]
    /// PR id → the Claude Code session linked to it in AI Review.
    var agentLinks: [String: AgentLink] { didSet { save(agentLinksFile, agentLinks) } }
    var runningAgents: [RunningAgent] = []
    /// Stored Claude Code sessions, newest first; stopped ones can be linked too.
    var recentSessions: [RunningAgent] = []

    let notifier = Notifier()
    /// Captured from SwiftUI so notifications and the menu bar can reopen a closed window.
    var openMainWindow: (() -> Void)?

    static let tools = ["gh", "claude", "codex", "ollama", "git"]
    /// Where each CLI was found at launch.
    let toolPaths: [String: String]
    let github: GitHub
    let reviewer: AIReviewer
    let agents: ClaudeAgents
    private let orgFile = JSONFile<Organization>.appSupport("organization.json")
    private let checkpointFile = JSONFile<[String: Snapshot]>.appSupport("checkpoints.json")
    private let draftsFile = JSONFile<ReviewDrafts>.appSupport("drafts.json")
    private let aiRunsFile = JSONFile<[AIRun]>.appSupport("ai-runs.json")
    private let agentLinksFile = JSONFile<[String: AgentLink]>.appSupport("agent-links.json")
    private var pollTask: Task<Void, Never>?

    init() {
        let overrides = Self.tools.reduce(into: [String: String]()) { $0[$1] = UserDefaults.standard.string(forKey: "path.\($1)") }
        // osascript opens background agents in Terminal; it's part of macOS.
        let runner = ProcessRunner(paths: ProcessRunner.discover(Self.tools, overrides: overrides).merging(["osascript": "/usr/bin/osascript"]) { a, _ in a })
        toolPaths = runner.paths
        github = GitHub(runner: runner)
        org = orgFile.load(default: Organization())
        checkpoints = checkpointFile.load(default: [:])
        reviewDrafts = draftsFile.load(default: ReviewDrafts())
        aiRuns = aiRunsFile.load(default: [])
        reviewer = AIReviewer(runner: runner)
        agents = ClaudeAgents(runner: runner)
        agentLinks = agentLinksFile.load(default: [:])
    }

    var selectedPR: PullRequest? { selectedPRID.flatMap { prs[$0] } }

    var allItems: [Item] { Stacks.items(Array(prs.values)) }

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
        guard let pr = prs[prID] else { return }
        reveal(pr)
        selection = [.pr(prID)]
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
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

    func deleteFolder(_ id: UUID) {
        org.deleteFolder(id)
        selection = selection.filter { if case .folder(let folder) = $0 { org.folders.contains { $0.id == folder } } else { true } }
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
