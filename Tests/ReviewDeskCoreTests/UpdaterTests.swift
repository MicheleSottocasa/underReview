import CryptoKit
import Foundation
import Testing
@testable import ReviewDeskCore

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rd-update-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let dmgBytes = Data("pretend dmg".utf8)
private let goodDigest = "sha256:" + SHA256.hash(data: dmgBytes).map { String(format: "%02x", $0) }.joined()

private func release(digest: String? = goodDigest) -> AppRelease {
    AppRelease(version: "0.7.0", url: "u", publishedAt: nil, notes: "", installer: .init(name: "ReviewDesk-0.7.0.dmg", digest: digest))
}

/// Answers `gh release download` by writing the "dmg" where it was asked to.
private func downloadingRunner() -> FakeRunner {
    FakeRunner { call in
        if call.tool == "gh", let dir = call.args.firstIndex(of: "-D").map({ call.args[$0 + 1] }) {
            try dmgBytes.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ReviewDesk-0.7.0.dmg"))
        }
        return ok("")
    }
}

@Test func latestReleaseFindsTheInstallerAndItsChecksum() async throws {
    let runner = FakeRunner { _ in
        ok(#"{"tag_name":"v0.7.0","html_url":"h","assets":[{"name":"notes.txt"},{"name":"ReviewDesk-0.7.0.dmg","digest":"sha256:ab"}]}"#)
    }
    let found = try await GitHub(runner: runner).latestRelease(repo: "o/r")
    #expect(found.installer == AppRelease.Installer(name: "ReviewDesk-0.7.0.dmg", digest: "sha256:ab"))
}

@Test func downloadChecksTheChecksum() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let runner = downloadingRunner()
    let file = try await Updater(runner: runner).download(release(), repo: "o/r", to: folder)
    #expect(file.lastPathComponent == "ReviewDesk-0.7.0.dmg")
    #expect(runner.calls.first?.args == ["release", "download", "v0.7.0", "-R", "o/r", "-p", "ReviewDesk-0.7.0.dmg", "-D", folder.path, "--clobber"])
    await #expect(throws: UpdateError.checksumMismatch("ReviewDesk-0.7.0.dmg")) {
        try await Updater(runner: downloadingRunner()).download(release(digest: "sha256:00"), repo: "o/r", to: folder)
    }
    var bare = release()
    bare.installer = nil
    await #expect(throws: UpdateError.noInstaller("0.7.0")) { try await Updater(runner: runner).download(bare, repo: "o/r", to: folder) }
}

/// A fake mounted installer holding an app with this bundle id and version.
private func mountingRunner(bundleID: String = "dev.reviewdesk.ReviewDesk", version: String = "0.7.0") -> FakeRunner {
    FakeRunner { call in
        switch (call.tool, call.args.first) {
        case ("hdiutil", "attach"):
            let mount = URL(fileURLWithPath: call.args[call.args.firstIndex(of: "-mountpoint")! + 1])
            let contents = mount.appendingPathComponent("ReviewDesk.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            NSDictionary(dictionary: ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version])
                .write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        case ("ditto", _):
            try FileManager.default.copyItem(atPath: call.args[0], toPath: call.args[1])
        default: break
        }
        return ok("")
    }
}

@Test func prepareChecksTheAppAndCopiesItOutUnquarantined() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let runner = mountingRunner()
    let app = try await Updater(runner: runner).prepare(folder.appendingPathComponent("x.dmg"), bundleID: "dev.reviewdesk.ReviewDesk", version: "0.7.0", in: folder)
    #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
    #expect(runner.calls.map { "\($0.tool) \($0.args.first ?? "")" } == ["hdiutil attach", "ditto \(folder.path)/mount/ReviewDesk.app", "hdiutil detach", "xattr -dr", "codesign --verify"])
}

@Test func prepareRefusesAnotherAppOrVersionAndUnmounts() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let runner = mountingRunner(version: "0.6.9")
    await #expect(throws: UpdateError.unexpectedApp("version 0.6.9, expected 0.7.0")) {
        try await Updater(runner: runner).prepare(folder.appendingPathComponent("x.dmg"), bundleID: "dev.reviewdesk.ReviewDesk", version: "0.7.0", in: folder)
    }
    #expect(runner.calls.last?.args.prefix(1) == ["detach"] && runner.calls.last?.args.last == "-force")
    #expect(!runner.calls.contains { $0.tool == "ditto" })
}

/// Runs the real install script in a sandbox: `open` and `lsregister` are replaced by `true`.
private func runInstallScript(newApp: URL, target: URL, work: URL) throws {
    let script = work.appendingPathComponent("install.sh")
    try Data(Updater.installScript.utf8).write(to: script)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    // No process 999999 is running, so the "wait for the app to quit" loop ends at once.
    process.arguments = [script.path, "999999", newApp.path, target.path, work.path]
    process.environment = ["OPEN": "/usr/bin/true", "LSREGISTER": work.deletingLastPathComponent().appendingPathComponent("lsregister").path, "PATH": "/usr/bin:/bin"]
    try process.run()
    process.waitUntilExit()
}

@Test func installScriptSwapsTheAppAndRollsBackOnFailure() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("Applications/ReviewDesk.app"), work = root.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: target.appendingPathComponent("version"))
    let newApp = work.appendingPathComponent("ReviewDesk.app")
    try FileManager.default.createDirectory(at: newApp, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: newApp.appendingPathComponent("version"))
    // A stand-in lsregister that records its arguments.
    let log = root.appendingPathComponent("lsregister.log"), fake = root.appendingPathComponent("lsregister")
    try Data("#!/bin/sh\necho \"$@\" >> '\(log.path)'\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

    try runInstallScript(newApp: newApp, target: target, work: work)
    #expect(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "new")
    // The temporary copy is forgotten and the installed one registered, so notifications keep the icon.
    #expect(try String(contentsOf: log, encoding: .utf8) == "-u \(newApp.path)\n-f \(target.path)\n")
    #expect(!FileManager.default.fileExists(atPath: target.path + ".previous"))
    #expect(!FileManager.default.fileExists(atPath: work.path)) // cleaned up

    // A copy that fails (the new app is missing) puts the installed one back.
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try runInstallScript(newApp: work.appendingPathComponent("missing.app"), target: target, work: work)
    #expect(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "new")
    #expect(!FileManager.default.fileExists(atPath: target.path + ".previous"))
}

@Test func launchForgetsEveryOtherRegisteredCopy() async {
    let runner = FakeRunner { _ in ok("") }
    let installed = URL(fileURLWithPath: "/Applications/ReviewDesk.app")
    let copies = [installed, URL(fileURLWithPath: "/private/var/folders/x/T/reviewdesk-update-1/ReviewDesk.app"),
                  URL(fileURLWithPath: "/Applications/./ReviewDesk.app"), URL(fileURLWithPath: "/Volumes/ReviewDesk/ReviewDesk.app")]
    await Updater(runner: runner).forgetOtherCopies(of: installed, among: copies)
    #expect(runner.calls.map(\.tool) == ["lsregister", "lsregister"])
    #expect(runner.calls.map(\.args) == [["-u", "/private/var/folders/x/T/reviewdesk-update-1/ReviewDesk.app"],
                                          ["-u", "/Volumes/ReviewDesk/ReviewDesk.app"]])
}
