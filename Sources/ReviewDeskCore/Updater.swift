import CryptoKit
import Foundation

public enum UpdateError: Error, LocalizedError, Equatable {
    case noInstaller(String)
    case checksumMismatch(String)
    case unexpectedApp(String)

    public var errorDescription: String? {
        switch self {
        case .noInstaller(let version): "Release \(version) has no installer attached."
        case .checksumMismatch(let name): "\(name) doesn't match GitHub's checksum, so it wasn't installed."
        case .unexpectedApp(let detail): "The installer doesn't hold the expected app: \(detail)."
        }
    }
}

/// Installs a new release in place: download the `.dmg` through `gh`, check it, copy the app out, then swap it
/// in after the running app quits. The download isn't quarantined (only browsers and quarantine-aware apps tag
/// files) and the mark is stripped anyway, so an update doesn't need the first install's right-click → Open.
public struct Updater: Sendable {
    public let runner: any CommandRunner

    public init(runner: any CommandRunner) { self.runner = runner }

    /// Tools outside the user's PATH lookups, at their fixed macOS locations.
    public static let systemTools = [
        "hdiutil": "/usr/bin/hdiutil", "ditto": "/usr/bin/ditto", "xattr": "/usr/bin/xattr",
        "codesign": "/usr/bin/codesign", "sh": "/bin/sh",
        "lsregister": "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
    ]

    /// Unregisters every copy of this app LaunchServices knows besides the installed one: an update's temporary
    /// copy (it can get registered again after the install script forgets it), a dev build or a mounted disk image.
    /// With one of those around, Notification Center shows a blank icon. Run at launch from the installed copy.
    public func forgetOtherCopies(of installed: URL, among copies: [URL]) async {
        let keep = installed.resolvingSymlinksInPath().standardizedFileURL.path
        for copy in copies where copy.resolvingSymlinksInPath().standardizedFileURL.path != keep {
            _ = try? await runner.run("lsregister", ["-u", copy.path], stdin: nil, cwd: nil, timeout: .seconds(30))
        }
    }

    /// Downloads the release's installer into `folder` and checks it against GitHub's checksum when there is one.
    public func download(_ release: AppRelease, repo: String, to folder: URL) async throws -> URL {
        guard let installer = release.installer else { throw UpdateError.noInstaller(release.version) }
        _ = try await runner.output("gh", ["release", "download", "v\(release.version)", "-R", repo, "-p", installer.name,
                                           "-D", folder.path, "--clobber"], timeout: .seconds(600))
        let file = folder.appendingPathComponent(installer.name)
        if let digest = installer.digest, digest.hasPrefix("sha256:") {
            let data = try Data(contentsOf: file)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard "sha256:\(actual)" == digest else { throw UpdateError.checksumMismatch(installer.name) }
        }
        return file
    }

    /// Mounts the installer read-only, checks the app inside (bundle id, version, signature) and copies it into
    /// `folder`, without the quarantine mark. Returns the copied app.
    public func prepare(_ dmg: URL, bundleID: String, version: String, in folder: URL) async throws -> URL {
        let mount = folder.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        _ = try await runner.output("hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path],
                                    timeout: .seconds(120))
        let app = folder.appendingPathComponent("ReviewDesk.app")
        do {
            let source = mount.appendingPathComponent("ReviewDesk.app")
            let info = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == bundleID else {
                throw UpdateError.unexpectedApp("bundle id \(info?["CFBundleIdentifier"] as? String ?? "missing")")
            }
            guard info?["CFBundleShortVersionString"] as? String == version else {
                throw UpdateError.unexpectedApp("version \(info?["CFBundleShortVersionString"] as? String ?? "missing"), expected \(version)")
            }
            _ = try await runner.output("ditto", [source.path, app.path], timeout: .seconds(120))
        } catch {
            _ = try? await runner.run("hdiutil", ["detach", mount.path, "-force"], stdin: nil, cwd: nil, timeout: .seconds(60))
            throw error
        }
        _ = try? await runner.run("hdiutil", ["detach", mount.path], stdin: nil, cwd: nil, timeout: .seconds(60))
        // The same as the one-time right-click → Open, for a file we downloaded and checked ourselves.
        _ = try? await runner.run("xattr", ["-dr", "com.apple.quarantine", app.path], stdin: nil, cwd: nil, timeout: .seconds(60))
        _ = try await runner.output("codesign", ["--verify", "--deep", app.path], timeout: .seconds(120))
        return app
    }

    /// Starts the helper that swaps `newApp` in for `installed` once process `pid` has quit, then relaunches it.
    /// It keeps the old copy until the new one is in place, and puts it back if the copy fails.
    public func scheduleInstall(_ newApp: URL, over installed: URL, after pid: Int32, folder: URL) async throws {
        let script = folder.appendingPathComponent("install.sh")
        try Data(Self.installScript.utf8).write(to: script)
        let quoted = [script.path, String(pid), newApp.path, installed.path, folder.path].map(Self.shellQuoted).joined(separator: " ")
        // Detached, so it outlives the app it replaces.
        _ = try await runner.output("sh", ["-c", "nohup /bin/sh \(quoted) >/dev/null 2>&1 &"])
    }

    static let installScript = """
    #!/bin/sh
    # ReviewDesk update: wait for the app to quit, swap the bundle (keeping the old one until the new one is in), relaunch.
    pid="$1"; new="$2"; target="$3"; work="$4"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.5; done
    rm -rf "$target.previous"
    if mv "$target" "$target.previous" && /usr/bin/ditto "$new" "$target"; then
        rm -rf "$target.previous"
    else
        rm -rf "$target"
        mv "$target.previous" "$target"
    fi
    # Forget the temporary copy and re-register the installed one, so Notification Center finds the icon
    # (a stale copy under the same bundle id blanks it); then relaunch. Both tools are overridable for tests.
    lsregister="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
    "$lsregister" -u "$new" 2>/dev/null
    "$lsregister" -f "$target"
    "${OPEN:-/usr/bin/open}" "$target"
    rm -rf "$work"
    """

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
