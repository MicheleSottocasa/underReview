import Foundation

/// Turns Claude Code's `stream-json` events into short steps the user can follow while a review runs.
public enum ClaudeActivity {
    /// What one event line says is happening; usually one step, none for bookkeeping events.
    public static func describe(_ line: String) -> [String] {
        guard let event = json(line), let type = event["type"] as? String else { return [] }
        switch (type, event["subtype"] as? String) {
        case ("system", "init"):
            return ["Claude Code started" + ((event["model"] as? String).map { " (\($0))" } ?? "")]
        case ("system", "task_started"):
            return ["Started " + ((event["description"] as? String).map { "“\($0)”" } ?? "a helper agent")]
        case ("system", "task_notification"):
            return [(event["status"] as? String) == "completed" ? "Helper agent finished" : "Helper agent stopped"]
        case ("assistant", _):
            return content(event).compactMap(step)
        case ("user", _):
            // Tool results: only failures are worth showing (e.g. a command the read-only allowlist refused).
            return content(event).compactMap { item in
                guard item["type"] as? String == "tool_result", item["is_error"] as? Bool == true else { return nil }
                return "A step was refused or failed: " + firstLine(text(of: item["content"]), limit: 100)
            }
        default:
            return []
        }
    }

    /// The session and task ids when this line says a helper agent started (how `/code-review` runs).
    public static func taskStarted(_ line: String) -> (session: String, task: String)? {
        guard let event = json(line), event["subtype"] as? String == "task_started",
              let session = event["session_id"] as? String, let task = event["task_id"] as? String else { return nil }
        return (session, task)
    }

    /// Events Claude Code forwards from a helper agent (they carry the tool call that started it).
    public static func isFromHelper(_ line: String) -> Bool {
        json(line)?["parent_tool_use_id"] is String
    }

    /// The final `result` event, shaped like `--output-format json` output; nil if the run never finished.
    public static func result(in stdout: Data) -> Data? {
        String(decoding: stdout, as: UTF8.self).split(separator: "\n").last { json(String($0))?["type"] as? String == "result" }
            .map { Data($0.utf8) }
    }

    private static func step(_ item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "thinking":
            return "Thinking…"
        case "text":
            let text = firstLine(item["text"] as? String ?? "", limit: 160)
            return text.isEmpty ? nil : "“\(text)”"
        case "tool_use":
            let input = item["input"] as? [String: Any] ?? [:]
            switch item["name"] as? String ?? "" {
            case "Bash": return "Running " + code(input["command"] as? String ?? "")
            case "Read": return "Reading " + code(shortPath(input["file_path"] as? String ?? ""))
            case "Grep": return "Searching for " + code(input["pattern"] as? String ?? "")
            case "Glob": return "Looking for files matching " + code(input["pattern"] as? String ?? "")
            case "Agent", "Task": return "Starting a helper agent: " + (input["description"] as? String ?? "")
            case let name: return "Using \(name)"
            }
        default:
            return nil
        }
    }

    private static func json(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    private static func content(_ event: [String: Any]) -> [[String: Any]] {
        (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    private static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    private static func firstLine(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > limit ? line.prefix(limit - 1) + "…" : line
    }

    private static func code(_ text: String) -> String { "`" + firstLine(text, limit: 90) + "`" }

    /// The last two components are enough to recognize a file.
    private static func shortPath(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }
}

// ponytail: mirrors Claude Code 2.1's on-disk layout to follow a helper agent live and to clean up after a run.
// If the layout changes, steps just arrive at the end of the run and cleanup finds nothing to remove.
/// The files Claude Code keeps for one session: `<config>/projects/<cwd, non-alphanumerics as "-">/<session>`.
public struct ClaudeSessionFiles: Sendable {
    public let projectDirectory: URL
    public let session: String

    public init(projectDirectory: URL, session: String) {
        self.projectDirectory = projectDirectory
        self.session = session
    }

    public init(configDirectory: URL, cwd: URL, session: String) {
        self.init(projectDirectory: Self.projectDirectory(configDirectory: configDirectory, cwd: cwd), session: session)
    }

    /// Where Claude Code files sessions run in `cwd`. Uses the real path (`/private/var/...`) as Claude Code does;
    /// Foundation's symlink resolution would turn it back into `/var/...`. `cwd` must exist.
    public static func projectDirectory(configDirectory: URL, cwd: URL) -> URL {
        var path = cwd.path
        if let resolved = realpath(cwd.path, nil) {
            path = String(cString: resolved)
            free(resolved)
        }
        let slug = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return configDirectory.appendingPathComponent("projects").appendingPathComponent(slug)
    }

    /// `CLAUDE_CONFIG_DIR`, or `~/.claude`.
    public static var defaultConfigDirectory: URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// A helper agent's transcript, written while it works.
    public func transcript(task: String) -> URL {
        projectDirectory.appendingPathComponent(session).appendingPathComponent("subagents").appendingPathComponent("agent-\(task).jsonl")
    }

    /// Deletes this session's files if they were created at or after `since`, and the project folder if it's
    /// then empty. Files from before (an existing session) are never touched.
    public func remove(createdSince since: Date) {
        let fm = FileManager.default
        for url in [projectDirectory.appendingPathComponent("\(session).jsonl"), projectDirectory.appendingPathComponent(session)] {
            guard let created = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date, created >= since else { continue }
            try? fm.removeItem(at: url)
        }
        if (try? fm.contentsOfDirectory(atPath: projectDirectory.path))?.isEmpty == true { try? fm.removeItem(at: projectDirectory) }
    }
}

/// Follows a file that may not exist yet, handing over each complete line, until cancelled; then drains it.
func followLines(of url: URL, onLine: @Sendable (String) -> Void) async {
    while !FileManager.default.fileExists(atPath: url.path) {
        if Task.isCancelled { return }
        try? await Task.sleep(for: .milliseconds(250))
    }
    await ProcessRunner.follow(url, onLine: onLine)
}

/// Live steps of a `/code-review` run: follows the helper's transcript once it starts, so its steps aren't
/// shown again when Claude Code forwards them at the end.
final class LiveReview: @unchecked Sendable {
    private let lock = NSLock()
    private var follower: Task<Void, Never>?
    private var transcript: URL?
    private var started: String?

    var session: String? { lock.withLock { started } }

    /// True once the transcript exists: the follower reads all of it, so forwarded copies can be skipped.
    var isFollowing: Bool {
        guard let url = lock.withLock({ transcript }) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func start(_ files: ClaudeSessionFiles, task: String, progress: @escaping @Sendable (String) -> Void) {
        lock.withLock {
            guard follower == nil else { return }
            started = files.session
            let url = files.transcript(task: task)
            transcript = url
            follower = Task.detached {
                await followLines(of: url) { line in ClaudeActivity.describe(line).forEach(progress) }
            }
        }
    }

    func stop() async {
        let task = lock.withLock { follower }
        task?.cancel()
        await task?.value
    }
}
