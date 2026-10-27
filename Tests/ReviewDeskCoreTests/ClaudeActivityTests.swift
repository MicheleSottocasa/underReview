import Foundation
import Testing
@testable import ReviewDeskCore

/// Event shapes as Claude Code 2.1 prints them with `--output-format stream-json --verbose`.
let streamedReview = [
    #"{"type":"system","subtype":"hook_started","hook_name":"SessionStart"}"#,
    #"{"type":"system","subtype":"task_started","description":"code review","subagent_type":"general-purpose"}"#,
    #"{"type":"system","subtype":"init","model":"claude-opus-5-5"}"#,
    #"{"type":"assistant","parent_tool_use_id":"t1","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr diff 1 -R o/r | head"}}]}}"#,
    #"{"type":"user","parent_tool_use_id":"t1","message":{"content":[{"type":"tool_result","is_error":true,"content":"This Bash command contains multiple operations.\nmore"}]}}"#,
    #"{"type":"assistant","parent_tool_use_id":"t1","message":{"content":[{"type":"thinking","thinking":"hm"},{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/x/pkg/cmd/setdefault.go"}}]}}"#,
    #"{"type":"user","parent_tool_use_id":"t1","message":{"content":[{"type":"tool_result","is_error":false,"content":"package main"}]}}"#,
    #"{"type":"assistant","message":{"content":[{"type":"text","text":"No problems found.\nDetails follow."}]}}"#,
    #"{"type":"system","subtype":"task_notification","status":"completed"}"#,
    #"{"type":"result","subtype":"success","is_error":false,"result":"No problems found."}"#,
]

@Test func describesWhatClaudeIsDoing() {
    #expect(streamedReview.flatMap(ClaudeActivity.describe) == [
        "Started “code review”",
        "Claude Code started (claude-opus-5-5)",
        "Running `gh pr diff 1 -R o/r | head`",
        "A step was refused or failed: This Bash command contains multiple operations.",
        "Thinking…",
        "Reading `cmd/setdefault.go`",
        "“No problems found.”",
        "Helper agent finished",
    ])
}

@Test func findsTheFinalResultInAStream() throws {
    let stdout = Data(streamedReview.joined(separator: "\n").utf8)
    let result = try #require(ClaudeActivity.result(in: stdout))
    #expect(String(decoding: result, as: UTF8.self).contains(#""result":"No problems found.""#))
    #expect(ClaudeActivity.result(in: Data("not json\n{\"type\":\"assistant\"}".utf8)) == nil)
}

@Test func sessionFilesFollowClaudeCodesLayout() throws {
    let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("rd test.\(UUID().uuidString.prefix(4))")
    let files = ClaudeSessionFiles(configDirectory: URL(fileURLWithPath: "/cfg"), cwd: cwd, session: "S1")
    let slug = files.projectDirectory.lastPathComponent
    #expect(slug.hasPrefix("-") && !slug.contains(" ") && !slug.contains(".") && !slug.contains("/"))
    #expect(files.transcript(task: "T9").path.hasSuffix("/S1/subagents/agent-T9.jsonl"))
}

@Test func cleanupRemovesOnlyFilesFromThisRun() throws {
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("rd-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: config) }
    let cwd = URL(fileURLWithPath: "/tmp/project")
    let old = ClaudeSessionFiles(configDirectory: config, cwd: cwd, session: "OLD")
    try FileManager.default.createDirectory(at: old.projectDirectory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: old.projectDirectory.appendingPathComponent("OLD.jsonl"))
    let since = Date().addingTimeInterval(1)
    old.remove(createdSince: since) // created before `since`: an existing session, kept
    #expect(FileManager.default.fileExists(atPath: old.projectDirectory.appendingPathComponent("OLD.jsonl").path))

    let new = ClaudeSessionFiles(configDirectory: config, cwd: URL(fileURLWithPath: "/tmp/reviewdesk-ai-x"), session: "NEW")
    try FileManager.default.createDirectory(at: new.transcript(task: "T").deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: new.projectDirectory.appendingPathComponent("NEW.jsonl"))
    new.remove(createdSince: .distantPast)
    #expect(!FileManager.default.fileExists(atPath: new.projectDirectory.path)) // emptied, so the folder goes too
}

@Test func codeReviewFollowsTheHelperTranscriptAndCleansUp() async throws {
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("rd-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: config) }
    let transcript = [
        #"{"type":"user","message":{"content":[{"type":"text","text":"Review target"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t_diff","name":"Bash","input":{"command":"gh pr diff 1 -R o/r"}}]}}"#,
        // Read in the helper's transcript only: that counts as having seen the diff.
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t_diff","is_error":false,"content":"diff --git"}]}}"#,
    ]
    let runner = FakeRunner { call in
        if call.args.first == "auth" { return ok(#"{"loggedIn":true,"authMethod":"claude.ai"}"#) }
        if call.args.contains("--json-schema") {
            return ok(#"{"type":"result","is_error":false,"structured_output":{"summary":"ok","findings":[],"keyAreas":[],"risks":[]}}"#)
        }
        // Claude Code writes the session and the helper's transcript under the config folder.
        let files = ClaudeSessionFiles(configDirectory: config, cwd: try #require(call.cwd), session: "S1")
        let url = files.transcript(task: "T1")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(transcript.joined(separator: "\n").utf8).write(to: url)
        try Data("{}".utf8).write(to: files.projectDirectory.appendingPathComponent("S1.jsonl"))
        return ok([
            #"{"type":"system","subtype":"task_started","session_id":"S1","task_id":"T1","description":"/code-review"}"#,
            // Forwarded copy of a helper step: already shown from the transcript.
            #"{"type":"assistant","parent_tool_use_id":"t1","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr diff 1 -R o/r"}}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"No problems."}"#,
        ].joined(separator: "\n"))
    }
    let steps = StepLog()
    let context = ReviewContext(title: "T", body: "", files: [], budget: 1000)
    _ = try await AIReviewer(runner: runner, claudeConfigDirectory: config)
        .codeReview(.claudeCode, prURL: "u", context: context, options: AIOptions()) { steps.append($0) }

    #expect(steps.value.filter { $0 == "Running `gh pr diff 1 -R o/r`" }.count == 1)
    let projects = (try? FileManager.default.contentsOfDirectory(atPath: config.appendingPathComponent("projects").path)) ?? []
    #expect(projects.isEmpty) // the run's session files are gone
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    var value: [String] { lock.withLock { steps } }
    func append(_ step: String) { lock.withLock { steps.append(step) } }
}

@Test func projectFolderUsesTheRealPathLikeClaudeCode() throws {
    // /var is a symlink to /private/var on macOS; Claude Code names folders after the real path.
    let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("rd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cwd) }
    let folder = ClaudeSessionFiles.projectDirectory(configDirectory: URL(fileURLWithPath: "/cfg"), cwd: cwd).lastPathComponent
    #expect(folder.hasPrefix("-private-var-") || !cwd.path.hasPrefix("/var/"))
}

@Test func plainClaudeRunsLeaveNoProjectFolder() async throws {
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("rd-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: config) }
    let runner = FakeRunner { call in
        if call.args.first == "auth" { return ok(#"{"loggedIn":true,"authMethod":"claude.ai"}"#) }
        // Claude Code creates the project's memory folder even for unsaved runs.
        let project = ClaudeSessionFiles.projectDirectory(configDirectory: config, cwd: try #require(call.cwd))
        try FileManager.default.createDirectory(at: project.appendingPathComponent("memory"), withIntermediateDirectories: true)
        return ok(#"{"type":"result","is_error":false,"result":"An answer."}"#)
    }
    _ = try await AIReviewer(runner: runner, claudeConfigDirectory: config).ask(.claudeCode, prompt: "p")
    let left = (try? FileManager.default.contentsOfDirectory(atPath: config.appendingPathComponent("projects").path)) ?? []
    #expect(left.isEmpty)
}
