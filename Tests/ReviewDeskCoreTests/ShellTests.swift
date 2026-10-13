import Foundation
import Testing
@testable import ReviewDeskCore

@Test func runnerPassesStdinAndCapturesOutput() async throws {
    let runner = ProcessRunner(paths: ["cat": "/bin/cat", "sh": "/bin/sh"])
    let echoed = try await runner.output("cat", [], stdin: Data("hello".utf8))
    #expect(String(decoding: echoed, as: UTF8.self) == "hello")

    let failed = try await runner.run("sh", ["-c", "echo oops >&2; exit 3"])
    #expect(failed.status == 3)
    #expect(failed.stderr == "oops\n")
}

@Test func runnerTimesOut() async {
    let runner = ProcessRunner(paths: ["sleep": "/bin/sleep"])
    await #expect(throws: CommandError.timedOut("sleep")) {
        try await runner.run("sleep", ["5"], timeout: .milliseconds(200))
    }
}

@Test func runnerRejectsUnknownTool() async {
    await #expect(throws: CommandError.toolNotFound("nope")) {
        try await ProcessRunner(paths: [:]).run("nope", [])
    }
}

@Test func childEnvironmentDropsAPIKeys() {
    let env = ProcessRunner.childEnvironment(["ANTHROPIC_API_KEY": "x", "OPENAI_API_KEY": "y", "HOME": "/h",
                                              "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD": "1"])
    #expect(env["ANTHROPIC_API_KEY"] == nil && env["OPENAI_API_KEY"] == nil)
    #expect(env["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"] == nil) // no instructions from --add-dir folders
    #expect(env["HOME"] == "/h")
}

@Test func discoverFindsToolsOnLoginPath() {
    let paths = ProcessRunner.discover(["ls", "gh", "definitely-not-a-tool"], overrides: ["gh": "/custom/gh"])
    #expect(paths["ls"] == "/bin/ls")
    #expect(paths["gh"] == "/custom/gh")
    #expect(paths["definitely-not-a-tool"] == nil)
}

@Test func cancellingBeforeLaunchDoesNotCrash() async {
    let task = Task { try await ProcessRunner(paths: ["sleep": "/bin/sleep"]).run("sleep", ["5"]) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func lookupIgnoresShellGreetings() {
    #expect(ProcessRunner.lastPath(in: "Welcome back!\n/Users/me/.local/bin/claude\n") == "/Users/me/.local/bin/claude")
    #expect(ProcessRunner.lastPath(in: "ls: aliased to ls -G\n") == nil)
}

@Test func discoverFallsBackToInstallFolders() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bin-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let tool = "reviewdesk-fake-\(UUID().uuidString.prefix(8))"
    let path = dir.appendingPathComponent(tool).path
    FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

    #expect(ProcessRunner.discover([tool], fallbacks: [dir.path]) == [tool: path])
    #expect(ProcessRunner.discover([tool], fallbacks: []) == [:])
}

@Test func streamingHandsOverLinesWhileTheToolRuns() async throws {
    let runner = ProcessRunner(paths: ["sh": "/bin/sh"])
    let lines = LineCollector()
    // The second line arrives a second later: it must be seen before the tool exits, with nothing lost.
    let result = try await runner.stream("sh", ["-c", "echo one; sleep 1; printf 'two\\nthree'"], stdin: nil, cwd: nil,
                                         timeout: .seconds(10)) { lines.append($0) }
    let finished = Date()
    #expect(lines.value == ["one", "two", "three"])
    #expect(finished.timeIntervalSince(try #require(lines.firstSeen)) > 0.5) // "one" came during the sleep
    #expect(result.text == "one\ntwo\nthree")
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var first: Date?
    var value: [String] { lock.withLock { lines } }
    var firstSeen: Date? { lock.withLock { first } }
    func append(_ line: String) { lock.withLock { lines.append(line); first = first ?? Date() } }
}

@Test func cancellationsAreNotShownAsErrors() async throws {
    // A view that goes away cancels its loading; the runner then throws a CancellationError.
    let runner = ProcessRunner(paths: ["sh": "/bin/sh"])
    let work = Task { try await runner.run("sh", ["-c", "sleep 5"], stdin: nil, cwd: nil, timeout: .seconds(10)) }
    try await Task.sleep(for: .milliseconds(100))
    work.cancel()
    let error = await #expect(throws: CancellationError.self) { try await work.value }
    #expect(error?.userMessage == nil)
    #expect(URLError(.cancelled).userMessage == nil)
    #expect(GitHubError.notFound("Pull request").userMessage == "Pull request not found or not accessible.")
}

@Test func childEnvironmentPutsTheToolFoldersOnPATH() {
    // What an app opened from Finder gets from launchd.
    let env = ProcessRunner.childEnvironment(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "ANTHROPIC_API_KEY": "x"],
                                             toolPaths: ["gh": "/opt/homebrew/bin/gh", "claude": "/Users/me/.local/bin/claude"])
    let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
    #expect(path.prefix(2) == ["/Users/me/.local/bin", "/opt/homebrew/bin"]) // the tools we resolved come first
    #expect(path.contains("/usr/bin") && path.contains("/sbin"))           // the original entries stay
    #expect(path.count == Set(path).count)                                 // no duplicates
    #expect(env["ANTHROPIC_API_KEY"] == nil)
}

@Test func childProcessesCanRunOtherDiscoveredTools() async throws {
    // A Finder-like PATH in the parent, but `sh` started through the runner still finds `gh`'s folder.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rd-path-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fakeGh = folder.appendingPathComponent("gh")
    try Data("#!/bin/sh\necho found-gh\n".utf8).write(to: fakeGh)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGh.path)
    let runner = ProcessRunner(paths: ["sh": "/bin/sh", "gh": fakeGh.path])
    let result = try await runner.run("sh", ["-c", "PATH_BEFORE=1 gh"], stdin: nil, cwd: nil, timeout: .seconds(10))
    #expect(result.text.trimmingCharacters(in: .whitespacesAndNewlines) == "found-gh")
}
