import AppKit
import ReviewDeskCore

extension AppModel {
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
            updateCheckError = error.localizedDescription
        }
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
                alert.informativeText = "You have \(currentVersion). Download the new installer from the release page."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { openRelease(release) }
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
