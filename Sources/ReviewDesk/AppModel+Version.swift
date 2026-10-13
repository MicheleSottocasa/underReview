import AppKit
import ReviewDeskCore

extension AppModel {
    static let betaNotice = "ReviewDesk is a beta preview: there is no stable release yet. Expect rough edges, and report problems on GitHub."

    /// This build's version and build number, from the bundle; "dev" when run without one (`swift run`).
    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    /// The update to show in the sidebar: newer than this build and not put off with "Later".
    var visibleUpdate: AppRelease? {
        availableUpdate.flatMap { $0.version == dismissedUpdate ? nil : $0 }
    }

    /// Called from the poll loop: checks at launch, then every few hours, unless turned off in Settings.
    func checkForUpdatesIfDue() async {
        guard UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true else { return }
        if let last = lastUpdateCheck, Date.now.timeIntervalSince(last) < AppVersion.checkInterval { return }
        await checkForUpdates()
    }

    func checkForUpdates() async {
        do {
            let release = try await github.latestRelease(repo: AppVersion.repository)
            lastUpdateCheck = .now
            updateCheckError = nil
            // A "dev" build (no bundle) has nothing to compare; don't nag.
            guard currentVersion != "dev", AppVersion.isNewer(release.version, than: currentVersion) else {
                availableUpdate = nil
                return
            }
            availableUpdate = release
            // One system notification per version, even across restarts.
            if UserDefaults.standard.string(forKey: "notifiedUpdate") != release.version {
                notifier.postUpdate(release)
                UserDefaults.standard.set(release.version, forKey: "notifiedUpdate")
            }
        } catch {
            lastUpdateCheck = .now // retry at the next interval, not on every poll
            updateCheckError = error.userMessage
        }
    }

    /// The app can replace itself: it runs from a `.app` in a folder it can write to (not `swift run`, not a disk image).
    var canInstallUpdates: Bool {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" && FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// Downloads the release, checks it, and swaps it in after quitting; ReviewDesk relaunches by itself.
    func installUpdate(_ release: AppRelease) {
        guard canInstallUpdates, release.installer != nil else { return openRelease(release) }
        guard aiStatus.isEmpty, stackRuns.values.allSatisfy(\.isFinished) else {
            lastError = "An AI review is running: install the update when it's done (relaunching would cancel it)."
            return
        }
        guard updateProgress == nil else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reviewdesk-update-\(UUID().uuidString)")
        let updater = Updater(runner: github.runner)
        updateProgress = "Downloading ReviewDesk \(release.version)…"
        Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let dmg = try await updater.download(release, repo: AppVersion.repository, to: folder)
                updateProgress = "Checking the installer…"
                let app = try await updater.prepare(dmg, bundleID: Bundle.main.bundleIdentifier ?? "", version: release.version, in: folder)
                updateProgress = "Installing \(release.version): ReviewDesk relaunches in a moment…"
                try await updater.scheduleInstall(app, over: Bundle.main.bundleURL, after: ProcessInfo.processInfo.processIdentifier, folder: folder)
                NSApp.terminate(nil)
            } catch {
                updateProgress = nil
                try? FileManager.default.removeItem(at: folder)
                report(error, "Couldn't install ReviewDesk \(release.version)")
            }
        }
    }

    /// The CHANGELOG.md sections up to this build, from the copy `make app` puts in the bundle (none under `swift run`).
    private func bundledNotes(after previous: String) -> [VersionNotes] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let changelog = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return AppVersion.notes(in: changelog, after: previous, through: currentVersion)
    }

    /// This version's own section (or the newest before it, when it has none).
    private var currentNotes: [VersionNotes] { Array(bundledNotes(after: "0").prefix(1)) }

    /// At launch: once after an update, what changed since the version that ran before. Then remembers this one.
    func showWhatsNewAfterUpdate() {
        let defaults = UserDefaults.standard
        let launch = AppVersion.launchNotes(lastLaunched: defaults.string(forKey: "lastLaunchedVersion"), current: currentVersion,
                                            existingUser: defaults.bool(forKey: "tourSeen"))
        if currentVersion != "dev" { defaults.set(currentVersion, forKey: "lastLaunchedVersion") }
        let notes = switch launch {
        case .since(let previous)?: bundledNotes(after: previous)
        case .thisVersion?: currentNotes
        case nil: [VersionNotes]()
        }
        if !notes.isEmpty { whatsNew = .installed(notes) }
    }

    /// Help › What's New: this version's notes.
    func showCurrentNotes() {
        openMainWindow?()
        whatsNew = .installed(currentNotes)
    }

    func openRelease(_ release: AppRelease) {
        if let url = URL(string: release.url) { NSWorkspace.shared.open(url) }
    }

    /// "Check for Updates…" in the app menu: always answers, even when up to date.
    func checkForUpdatesFromMenu() {
        Task {
            await checkForUpdates()
            let alert = NSAlert()
            if let release = availableUpdate {
                dismissedUpdate = nil
                alert.messageText = "ReviewDesk \(release.version) is available"
                alert.informativeText = canInstallUpdates
                    ? "You have \(currentVersion). ReviewDesk can download, check and install it, then relaunch."
                    : "You have \(currentVersion). Download the new installer from the release page."
                alert.addButton(withTitle: canInstallUpdates ? "Install and Relaunch" : "Download")
                alert.addButton(withTitle: "What's New")
                alert.addButton(withTitle: "Later")
                switch alert.runModal() {
                case .alertFirstButtonReturn: installUpdate(release)
                case .alertSecondButtonReturn:
                    openMainWindow?()
                    whatsNew = .update(release)
                default: break
                }
            } else if let error = updateCheckError {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = error
                alert.runModal()
            } else {
                alert.messageText = "ReviewDesk is up to date"
                alert.informativeText = "You have the latest version, \(currentVersion)."
                alert.runModal()
            }
        }
    }
}
