import AppKit
import Observation
import ReviewDeskCore
import SwiftUI

/// Re-run from a stale-analysis banner with Codex or Ollama: the AI tab prepares the context for this engine.
struct ContextRequest: Equatable {
    let prID: String
    let engine: AIEngine
}

struct RecentEvent: Identifiable {
    let id = UUID()
    let pr: PullRequest
    let kinds: [UpdateKind]
    let date = Date()
}

/// Sidebar state filter; Draft is an open PR marked as draft.
enum PRStateFilter: String, CaseIterable {
    case open, changed, draft, merged, closed

    var title: String { self == .changed ? "Changed Since Review" : rawValue.capitalized }

    /// One category per PR: an open PR with new commits since the viewer's review is "changed", not "open".
    func matches(_ pr: PullRequest) -> Bool {
        switch self {
        case .open: pr.state == "OPEN" && !pr.isDraft && !pr.needsReReview
        case .changed: pr.needsReReview && !pr.isDraft
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
    /// Comment, thread, draft, file and agent ids with an action in flight, until its new state has loaded.
    var pending: Set<String> = []

    /// Every PR we track, by node id.
    var prs: [String: PullRequest] = [:]
    var inboxIDs: Set<String> = []
    var details: [String: PRDetail] = [:]
    /// Changed files per PR, fetched on demand and kept in memory only, and the head each list is from.
    var files: [String: [FileChange]] = [:]
    var filesHead: [String: String] = [:]
    /// Paths marked as viewed on GitHub, per PR. GitHub is the source of truth; nothing is stored locally.
    var viewedFiles: [String: Set<String>] = [:]
    /// The PR detail tab, here so other tabs can send the user to Changes.
    var detailTab = DetailTab.conversation
    /// The onboarding tour's current card, while it runs.
    var tourStep: TourStep?
    /// A file and line for the Changes tab to open next.
    var changesTarget: LineTarget?
    /// PR id → the commits Changes shows and the head they were picked at. In memory only.
    var commitSelections: [String: (selection: CommitSelection, head: String)] = [:]
    /// `comparisonKey` → the files changed between two commits, fetched when first shown.
    var comparisons: [String: [FileChange]] = [:]
    /// Comparisons GitHub couldn't make, and why: Changes says so and falls back to the whole diff.
    var missingComparisons: [String: String] = [:]
    /// PR id → risk question → head commit it was checked at. Kept locally, never sent anywhere.
    var riskChecks: [String: [String: String]] { didSet { save(riskChecksFile, riskChecks.filter { !Demo.owns($0.key) }) } }
    /// PR id → key area (`KeyArea.readKey`) → head commit it was read at. Kept locally, like `riskChecks`.
    var readAreas: [String: [String: String]] { didSet { save(readAreasFile, readAreas.filter { !Demo.owns($0.key) }) } }

    /// Sidebar multi-selection. The detail follows the last single-selected PR and stays put otherwise.
    var selection: Set<SidebarID> = [] {
        didSet {
            guard selection.count == 1, case .pr(let id)? = selection.first, id != selectedPRID else { return }
            selectedPRID = id
            Task { await loadDetail(id) }
        }
    }
    var selectedPRID: String? {
        // A Re-run request belongs to the PR it was made on; another PR's AI tab must not pick it up.
        didSet { if contextRequest?.prID != selectedPRID { contextRequest = nil } }
    }
    var filter = ""
    /// States shown in the sidebar. Persisted; all by default.
    var stateFilter: Set<PRStateFilter> = AppModel.savedStateFilter() {
        didSet { UserDefaults.standard.set(stateFilter.map(\.rawValue), forKey: "stateFilter") }
    }
    /// When the PR list last refreshed successfully, and why the latest refresh failed, if it did.
    var lastRefresh: Date?
    var refreshError: String?
    /// From launch until the first refresh succeeds or fails, and during every later refresh.
    /// Until the viewer is known (no refresh can run before), and during every refresh.
    var isLoading: Bool { isRefreshing || (viewer.isEmpty && setupError == nil) }
    /// A newer published release than this build, if the last check found one.
    var availableUpdate: AppRelease?
    /// The "What's New" sheet open in the main window.
    var whatsNew: WhatsNew?
    /// What the in-app update is doing (downloading, checking, installing), while it runs.
    var updateProgress: String?
    var lastUpdateCheck: Date?
    var updateCheckError: String?
    /// The release the user chose "Later" for: its banner stays hidden until a newer one comes out.
    var dismissedUpdate = UserDefaults.standard.string(forKey: "dismissedUpdate") {
        didSet { UserDefaults.standard.set(dismissedUpdate, forKey: "dismissedUpdate") }
    }
    /// Expansion keys that differ from the default (folders open, stacks closed). Persisted.
    var toggledExpansion: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "toggledExpansion") ?? []) {
        didSet { UserDefaults.standard.set(Array(toggledExpansion), forKey: "toggledExpansion") }
    }
    var columns: NavigationSplitViewVisibility = .all
    /// Set when the Changes tab hid the sidebar, so leaving it only restores what the app hid.
    var sidebarAutoHidden = false

    // The tour's demo lives in these in memory only: every save drops it.
    var org: Organization { didSet { save(orgFile, org.removingDemo()) } }
    var checkpoints: [String: Snapshot]
    var reviewDrafts: ReviewDrafts { didSet { save(draftsFile, reviewDrafts.removingDemo()) } }
    var recentEvents: [RecentEvent] = []
    /// Events added since the notifications list was last opened.
    var unseenEvents = 0
    var aiRuns: [AIRun] { didSet { save(aiRunsFile, aiRuns.filter { !Demo.owns($0.prID) }) } }
    /// Checks of whether the author handled the viewer's comments, newest last.
    var followUps: [FollowUpRun] { didSet { save(followUpsFile, followUps.filter { !Demo.owns($0.prID) }) } }
    /// Project (top-level folder) id → extra AI context sent with its pull requests.
    var projectContext: [UUID: [ContextSource]] { didSet { save(projectContextFile, projectContext) } }
    /// PR id → what the AI is doing right now.
    var aiStatus: [String: String] = [:]
    /// PR id → the latest steps of a running review, newest last; cleared when it ends.
    var aiActivity: [String: [AIStep]] = [:]
    /// Stack reviews by the PR they were started from: one agent per PR, kept until dismissed so each log can be read.
    var stackRuns: [String: StackRun] = [:]
    /// Comment id → AI explanation. In memory only: a fresh one is a click away.
    var explanations: [String: Explanation] = [:]
    /// Finding ("run#index") or comment id → the AI's proposed fix, waiting for the reviewer. In memory only.
    var fixes: [String: Fix] = [:]
    var aiTasks: [String: Task<Void, Never>] = [:]
    /// "oldHead..newHead" → commits pushed in between (nil: unknown), for the stale-analysis banner. In memory only.
    var commitsSince: [String: Int?] = [:]
    /// A PR whose AI tab should prepare the context as soon as it shows (Re-run with Codex or Ollama).
    var contextRequest: ContextRequest?
    /// PR id → the Claude Code session linked to it in AI Review.
    var agentLinks: [String: AgentLink] { didSet { save(agentLinksFile, agentLinks.filter { !Demo.owns($0.key) }) } }
    var runningAgents: [RunningAgent] = []
    /// Repository (`owner/repo`) → the folder of its clone on this Mac.
    var localClones: [String: String] { didSet { save(localClonesFile, localClones) } }
    /// Clone folders a checkout is running in, so a second one can't start there at the same time.
    var checkingOut: Set<String> = []
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
    let clones: LocalClone
    private let orgFile = JSONFile<Organization>.appSupport("organization.json")
    private let checkpointFile = JSONFile<[String: Snapshot]>.appSupport("checkpoints.json")
    private let draftsFile = JSONFile<ReviewDrafts>.appSupport("drafts.json")
    private let aiRunsFile = JSONFile<[AIRun]>.appSupport("ai-runs.json")
    private let agentLinksFile = JSONFile<[String: AgentLink]>.appSupport("agent-links.json")
    private let riskChecksFile = JSONFile<[String: [String: String]]>.appSupport("risk-checks.json")
    private let readAreasFile = JSONFile<[String: [String: String]]>.appSupport("read-areas.json")
    private let followUpsFile = JSONFile<[FollowUpRun]>.appSupport("follow-ups.json")
    private let prsFile = JSONFile<PRCache>.appSupport("prs.json")
    private let localClonesFile = JSONFile<[String: String]>.appSupport("local-clones.json")
    private let projectContextFile = JSONFile<[UUID: [ContextSource]]>.appSupport("project-context.json")
    private var pollTask: Task<Void, Never>?
    private var lastFullRefresh = Date.distantPast

    init() {
        let overrides = Self.tools.reduce(into: [String: String]()) { $0[$1] = UserDefaults.standard.string(forKey: "path.\($1)") }
        // osascript opens background agents in Terminal; it's part of macOS.
        // osascript and the updater's tools ship with macOS, at fixed paths.
        let system = Updater.systemTools.merging(["osascript": "/usr/bin/osascript"]) { a, _ in a }
        let runner = ProcessRunner(paths: ProcessRunner.discover(Self.tools, overrides: overrides).merging(system) { a, _ in a })
        toolPaths = runner.paths
        github = GitHub(runner: runner)
        let org = orgFile.load(default: Organization())
        self.org = org
        // The last list shows right away, marked by its age in the footer, until the first refresh replaces it.
        // A screenshot run must never show the user's own pull requests.
        let cache = Screenshots.isRequested ? PRCache() : prsFile.load(default: PRCache())
        prs = cache.prs.filter { !org.unfollowed.contains($0.key) }
        lastRefresh = cache.refreshed
        lastFullRefresh = cache.fullRefresh
        checkpoints = checkpointFile.load(default: [:])
        reviewDrafts = draftsFile.load(default: ReviewDrafts())
        aiRuns = aiRunsFile.load(default: [])
        reviewer = AIReviewer(runner: runner)
        agents = ClaudeAgents(runner: runner)
        clones = LocalClone(runner: runner)
        agentLinks = agentLinksFile.load(default: [:])
        riskChecks = riskChecksFile.load(default: [:])
        readAreas = readAreasFile.load(default: [:])
        followUps = followUpsFile.load(default: [])
        localClones = localClonesFile.load(default: [:])
        projectContext = projectContextFile.load(default: [:])
    }

    var selectedPR: PullRequest? { selectedPRID.flatMap { prs[$0] } }

    var allItems: [Item] { Stacks.items(Array(prs.values)) }

    // MARK: Lifecycle

    /// The saved filter, upgraded once for "changed since review": those PRs used to count as open, so a filter
    /// showing open PRs keeps showing them.
    static func savedStateFilter() -> Set<PRStateFilter> {
        let defaults = UserDefaults.standard
        guard var saved = defaults.stringArray(forKey: "stateFilter") else { return Set(PRStateFilter.allCases) }
        if !defaults.bool(forKey: "stateFilter.hasChanged") {
            if saved.contains(PRStateFilter.open.rawValue) { saved.append(PRStateFilter.changed.rawValue) }
            defaults.set(saved, forKey: "stateFilter")
            defaults.set(true, forKey: "stateFilter.hasChanged")
        }
        return Set(saved.compactMap(PRStateFilter.init))
    }

    func start() {
        // A screenshot run only shows the demo: no polling, no notifications, no GitHub calls.
        guard pollTask == nil, !Screenshots.isRequested else { return }
        showWhatsNewAfterUpdate()
        notifier.onOpen = { [weak self] id in self?.open(prID: id) }
        notifier.onOpenURL = { NSWorkspace.shared.open($0) }
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
                    report(error)
                    if let message = error.userMessage { refreshError = message }
                }
                await checkForUpdatesIfDue()
                let defaults = UserDefaults.standard
                try? await Task.sleep(for: Updates.interval(
                    foreground: NSApp.isActive, failures: failures,
                    foregroundSeconds: defaults.object(forKey: "pollForeground") as? Int ?? Updates.defaultForeground,
                    backgroundSeconds: defaults.object(forKey: "pollBackground") as? Int ?? Updates.defaultBackground))
            }
        }
    }

    func retrySetup() {
        pollTask?.cancel()
        pollTask = nil
        start()
    }

    func refresh() async throws {
        // Without the viewer, checkpoints would record no review request, and the next poll would announce one
        // for every PR that has it.
        guard !viewer.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Cheap pass first (ids and update times), then full data only for PRs that changed.
        let inbox = try await github.inbox()
        inboxIDs = Set(inbox.keys)
        let stamps = inbox.merging(try await github.updatedAt(ids: org.followed.keys.filter { inbox[$0] == nil })) { a, _ in a }
            .filter { !org.unfollowed.contains($0.key) }
        // ponytail: resolving a thread may not bump updatedAt, so a full pass every 10 min catches it. Its time is
        // cached with the list, so a relaunch reuses the cache; after switching `gh` account, unchanged PRs keep the
        // previous account's review state until the next full pass.
        let full = Date.now.timeIntervalSince(lastFullRefresh) > 600
        if full { lastFullRefresh = .now }
        var (fresh, fetched) = try await github.pullRequests(updatedAt: stamps, cached: full ? [:] : prs)
        let members = Stacks.missingMembers(of: Array(fresh.values)).filter { !org.unfollowed.contains($0) }
        fetched += members
        for pr in try await github.pullRequests(ids: members) { fresh[pr.id] = pr }

        // ponytail: everything seen is followed until the user stops monitoring it, so merges and closes
        // still notify. Merged PRs keep being polled; auto-archive them if the list grows too long.
        var updated = org
        for pr in fresh.values where updated.followed[pr.id] == nil && !updated.unfollowed.contains(pr.id) {
            updated.follow(id: pr.id, url: pr.url)
        }
        if updated != org { org = updated }
        // The tour's demo PRs aren't on GitHub: keep them through refreshes instead of dropping them.
        prs = fresh.filter { !org.unfollowed.contains($0.key) }.merging(prs.filter { $0.value.isDemo }) { real, _ in real }
        lastError = nil
        lastRefresh = .now
        refreshError = nil
        await didRefresh(Array(prs.values.filter { !$0.isDemo }))
        save(checkpointFile, checkpoints.filter { !Demo.owns($0.key) })
        save(prsFile, PRCache(prs: prs.filter { !$0.value.isDemo }, refreshed: lastRefresh, fullRefresh: lastFullRefresh))
        // The open PR's conversation is reloaded only when GitHub says it changed.
        if let id = selectedPRID, prs[id] != nil, details[id] == nil || fetched.contains(id) { await loadDetail(id) }
    }

    /// Hook for later features (notifications, stale drafts).
    func didRefresh(_ prs: [PullRequest]) async {
        let events = Updates.advance(&checkpoints, with: prs, viewer: viewer)
        for (id, kinds) in events {
            guard let pr = self.prs[id] else { continue }
            recentEvents.insert(RecentEvent(pr: pr, kinds: kinds), at: 0)
            unseenEvents += 1
            if !org.muted.contains(pr.itemKey) { notifier.post(pr, kinds: kinds) }
        }
        recentEvents = Array(recentEvents.prefix(50))
        unseenEvents = min(unseenEvents, recentEvents.count)
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
            do { try await refresh() } catch {
                report(error)
                if let message = error.userMessage { refreshError = message }
            }
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
        projectContext = projectContext.filter { entry in org.folders.contains { $0.id == entry.key } }
        selection = selection.filter { if case .folder(let folder) = $0 { org.folders.contains { $0.id == folder } } else { true } }
    }

    func loadDetail(_ id: String) async {
        guard !Demo.owns(id) else { return } // the demo's detail is canned; it isn't on GitHub
        // ponytail: last writer wins. A poll that started before our own write can land after its reload and show the
        // old state until the next poll; add a per-PR generation counter if that shows up in practice.
        do {
            details[id] = try await github.detail(id: id)
        } catch {
            report(error)
        }
    }

    func openOnGitHub(_ pr: PullRequest) {
        guard !blockDemo(pr) else { return }
        if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
    }

    /// Marks `id` pending while `work` runs, so views can disable and dim the item and show a spinner.
    /// Returns nil without running `work` when `id` is already pending, so two actions can't clear each other's state.
    @discardableResult
    func whilePending<T>(_ id: String, _ work: () async -> T) async -> T? {
        guard pending.insert(id).inserted else { return nil }
        defer { pending.remove(id) }
        return await work()
    }

    /// GitHub's comparison of the reviewed commit with the head. A compare page, not the PR's own range view,
    /// which 404s once a force-push dropped the reviewed commit from the PR.
    /// ponytail: opens GitHub; show it in Changes once it can pick a commit range (#35).
    func openChangesSinceReview(_ pr: PullRequest) {
        guard !blockDemo(pr), let old = pr.viewerReviewedOid,
              let url = URL(string: "https://github.com/\(pr.repo)/compare/\(old)..\(pr.headRefOid)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Shows an error in the banner, prefixed with what failed; cancellations (a closed view, Cancel) are dropped.
    func report(_ error: any Error, _ prefix: String? = nil) {
        guard let message = error.userMessage else { return }
        lastError = prefix.map { "\($0): \(message)" } ?? message
    }

    func save<T: Codable>(_ file: JSONFile<T>, _ value: T) {
        guard !Screenshots.isRequested else { return } // a screenshot run must never touch the user's files
        do { try file.save(value) } catch { lastError = "Couldn't save \(file.url.lastPathComponent): \(error.localizedDescription)" }
    }
}
