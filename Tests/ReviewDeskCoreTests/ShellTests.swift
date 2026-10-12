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
    let env = ProcessRunner.childEnvironment(["ANTHROPIC_API_KEY": "x", "OPENAI_API_KEY": "y", "HOME": "/h"])
    #expect(env == ["HOME": "/h"])
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
