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

    /// GUI apps don't inherit the shell PATH, so ask a login shell where each tool lives.
    public static func discover(_ tools: [String], overrides: [String: String] = [:]) -> [String: String] {
        var found: [String: String] = [:]
        for tool in tools {
            if let path = overrides[tool], !path.isEmpty { found[tool] = path; continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v \(tool)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, path.hasPrefix("/") { found[tool] = path }
        }
        return found
    }

    public static func childEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.filter { !strippedEnvironment.contains($0.key) }
    }

    public func run(_ tool: String, _ args: [String], stdin: Data?, cwd: URL?, timeout: Duration) async throws -> CommandResult {
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
