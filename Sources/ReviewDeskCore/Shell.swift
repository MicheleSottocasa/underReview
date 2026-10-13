import Foundation

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data, stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

public enum CommandError: Error, Equatable, LocalizedError {
    case toolNotFound(String)
    case timedOut(String)
    case failed(tool: String, status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool): "`\(tool)` not found. Install it or set its path in Settings."
        case .timedOut(let tool): "`\(tool)` timed out."
        case .failed(let tool, let status, let stderr): "`\(tool)` exited with \(status): \(stderr)"
        }
    }
}

/// Seam for tests: everything external (gh, claude, codex, ollama) goes through here.
public protocol CommandRunner: Sendable {
    func run(_ tool: String, _ args: [String], stdin: Data?, cwd: URL?, timeout: Duration) async throws -> CommandResult
    /// Like `run`, also handing each complete line of stdout to `onLine` while the tool is still running.
    func stream(_ tool: String, _ args: [String], stdin: Data?, cwd: URL?, timeout: Duration,
                onLine: @escaping @Sendable (String) -> Void) async throws -> CommandResult
}

extension CommandRunner {
    /// Runners that can't stream hand the lines over at the end, which is all tests need.
    public func stream(_ tool: String, _ args: [String], stdin: Data?, cwd: URL?, timeout: Duration,
                       onLine: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        let result = try await run(tool, args, stdin: stdin, cwd: cwd, timeout: timeout)
        for line in result.text.split(separator: "\n") { onLine(String(line)) }
        return result
    }
}

extension CommandRunner {
    public func run(_ tool: String, _ args: [String], stdin: Data? = nil, cwd: URL? = nil, timeout: Duration = .seconds(60)) async throws -> CommandResult {
        try await run(tool, args, stdin: stdin, cwd: cwd, timeout: timeout)
    }

    /// Runs and throws on non-zero exit.
    public func output(_ tool: String, _ args: [String], stdin: Data? = nil, cwd: URL? = nil, timeout: Duration = .seconds(60)) async throws -> Data {
        let result = try await run(tool, args, stdin: stdin, cwd: cwd, timeout: timeout)
        guard result.status == 0 else { throw CommandError.failed(tool: tool, status: result.status, stderr: result.stderr) }
        return result.stdout
    }
}

public struct ProcessRunner: CommandRunner {
    /// API keys would make the AI CLIs bill the API instead of the user's subscription.
    public static let strippedEnvironment: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
        "OPENAI_API_KEY", "CODEX_API_KEY",
    ]

    public var paths: [String: String]

    public init(paths: [String: String]) { self.paths = paths }

    /// Where installers commonly put CLIs, checked when the shell doesn't know a tool.
    public static let fallbackDirectories = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.bun/bin", "~/.npm-global/bin"]

    /// GUI apps don't inherit the shell PATH. Ask an interactive login shell (many installers only touch
    /// `.zshrc`, e.g. Claude Code's `~/.local/bin`), then fall back to common install folders.
    public static func discover(_ tools: [String], overrides: [String: String] = [:],
                                fallbacks: [String] = fallbackDirectories) -> [String: String] {
        var found: [String: String] = [:]
        for tool in tools {
            if let path = overrides[tool], !path.isEmpty {
                found[tool] = path
            } else if let path = shellLookup(tool) {
                found[tool] = path
            } else if let path = fallbacks.map({ (($0 as NSString).expandingTildeInPath as NSString).appendingPathComponent(tool) })
                .first(where: FileManager.default.isExecutableFile(atPath:)) {
                found[tool] = path
            }
        }
        return found
    }

    static func shellLookup(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "whence -p \(tool)"] // paths only: aliases and functions from .zshrc are skipped
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice // an interactive .zshrc must never wait for input
        guard (try? process.run()) != nil else { return nil }
        // ponytail: a 10 s cap per tool so a slow .zshrc can't hang launch; lower it if startup feels slow.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return lastPath(in: String(decoding: data, as: UTF8.self))
    }

    /// `.zshrc` may print greetings; the answer is the last line that is an absolute path.
    static func lastPath(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
    }

    /// Reads lines appended to `url` until cancelled, then drains what's left so no line is lost.
    static func follow(_ url: URL, onLine: @Sendable (String) -> Void) async {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                onLine(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
    }

    public static func childEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.filter { !strippedEnvironment.contains($0.key) }
    }

    public func run(_ tool: String, _ args: [String], stdin: Data?, cwd: URL?, timeout: Duration) async throws -> CommandResult {
        try await execute(tool, args, stdin: stdin, cwd: cwd, timeout: timeout, onLine: nil)
    }

    public func stream(_ tool: String, _ args: [String], stdin: Data?, cwd: URL?, timeout: Duration,
                       onLine: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        try await execute(tool, args, stdin: stdin, cwd: cwd, timeout: timeout, onLine: onLine)
    }

    private func execute(_ tool: String, _ args: [String], stdin: Data?, cwd: URL?, timeout: Duration,
                         onLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        guard let path = paths[tool] else { throw CommandError.toolNotFound(tool) }
        // Temp files instead of pipes: no buffer deadlocks, no reader threads.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reviewdesk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in"), outURL = dir.appendingPathComponent("out"), errURL = dir.appendingPathComponent("err")
        try (stdin ?? Data()).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = Self.childEnvironment()
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = try FileHandle(forReadingFrom: inURL)
        process.standardOutput = try FileHandle(forWritingTo: outURL)
        process.standardError = try FileHandle(forWritingTo: errURL)

        // Streaming follows the output file instead of using a pipe, keeping the no-pipe design above.
        let tail = onLine.map { onLine in Task.detached { await Self.follow(outURL, onLine: onLine) } }
        let start = ContinuousClock.now
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in done.resume() }
                guard !Task.isCancelled else { return done.resume(throwing: CancellationError()) }
                do { try process.run() } catch { done.resume(throwing: error) }
            }
        } onCancel: {
            // terminate() on a process that never launched raises an Objective-C exception.
            if process.isRunning { process.terminate() }
        }
        tail?.cancel()
        await tail?.value
        try Task.checkCancellation()
        if process.terminationReason == .uncaughtSignal, ContinuousClock.now - start >= timeout {
            throw CommandError.timedOut(tool)
        }
        return CommandResult(
            status: process.terminationStatus,
            stdout: (try? Data(contentsOf: outURL)) ?? Data(),
            stderr: String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        )
    }
}

extension Error {
    /// The message to show the user, or nil for a cancellation: the user (or a closed view) stopped the work,
    /// so there's nothing to report.
    public var userMessage: String? {
        if self is CancellationError { return nil }
        if let urlError = self as? URLError, urlError.code == .cancelled { return nil }
        return localizedDescription
    }
}
