import Foundation

/// Tokens an AI run used, as its CLI reported them, added up over the run's passes (a `/code-review` has two).
public struct TokenUsage: Codable, Hashable, Sendable {
    /// Fresh input tokens (not read from or written to a cache).
    public var input = 0
    public var output = 0
    /// Input read from the provider's prompt cache: cheaper, but still counted against plan limits.
    public var cacheRead = 0
    /// Input written to the prompt cache.
    public var cacheWrite = 0
    /// Claude Code's list-price equivalent in US dollars. Runs use a subscription login, so it isn't a charge.
    public var listPriceUSD: Double?
    /// CLI calls added up here.
    public var passes = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, listPriceUSD: Double? = nil, passes: Int = 1) {
        (self.input, self.output, self.cacheRead, self.cacheWrite, self.listPriceUSD, self.passes) = (input, output, cacheRead, cacheWrite, listPriceUSD, passes)
    }

    /// Every token the run went through: input of all kinds plus output.
    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        let price: Double? = a.listPriceUSD == nil && b.listPriceUSD == nil ? nil : (a.listPriceUSD ?? 0) + (b.listPriceUSD ?? 0)
        return TokenUsage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                          cacheWrite: a.cacheWrite + b.cacheWrite, listPriceUSD: price, passes: a.passes + b.passes)
    }

    /// From Claude Code's final `result` event. `modelUsage` comes first: it covers every model and the helper agents a
    /// command like `/code-review` runs, while the top-level `usage` can be all zeros then.
    public static func claude(_ result: [String: Any]) -> TokenUsage? {
        let price = result["total_cost_usd"] as? Double
        let models = (result["modelUsage"] as? [String: [String: Any]] ?? [:]).values
        if !models.isEmpty {
            var usage = TokenUsage(listPriceUSD: price)
            for model in models {
                usage.input += model["inputTokens"] as? Int ?? 0
                usage.output += model["outputTokens"] as? Int ?? 0
                usage.cacheRead += model["cacheReadInputTokens"] as? Int ?? 0
                usage.cacheWrite += model["cacheCreationInputTokens"] as? Int ?? 0
            }
            if usage.total > 0 { return usage }
        }
        guard let top = result["usage"] as? [String: Any] else { return nil }
        let usage = TokenUsage(input: top["input_tokens"] as? Int ?? 0, output: top["output_tokens"] as? Int ?? 0,
                               cacheRead: top["cache_read_input_tokens"] as? Int ?? 0,
                               cacheWrite: top["cache_creation_input_tokens"] as? Int ?? 0, listPriceUSD: price)
        return usage.total > 0 ? usage : nil
    }

    /// From `codex exec --json` events: the `turn.completed` ones carry the usage. `input_tokens` includes the cached part.
    public static func codex(events: String) -> TokenUsage? {
        var usage: TokenUsage?
        for line in events.split(separator: "\n") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  event["type"] as? String == "turn.completed", let turn = event["usage"] as? [String: Any] else { continue }
            let cached = turn["cached_input_tokens"] as? Int ?? 0
            let input = max(0, (turn["input_tokens"] as? Int ?? 0) - cached)
            let output = (turn["output_tokens"] as? Int ?? 0) + (turn["reasoning_output_tokens"] as? Int ?? 0)
            let pass = TokenUsage(input: input, output: output, cacheRead: cached, cacheWrite: turn["cache_write_input_tokens"] as? Int ?? 0)
            usage = usage.map { $0 + pass } ?? pass
        }
        usage?.passes = 1 // one exec call, however many turns
        return usage
    }

    /// From `ollama run --verbose`, which prints its timings and counts on stderr.
    public static func ollama(stderr: String) -> TokenUsage? {
        func count(_ label: String) -> Int? {
            stderr.split(separator: "\n").lazy.compactMap { line -> Int? in
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix(label + ":") else { return nil }
                return Int(text.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
            }.first
        }
        let prompt = count("prompt eval count"), output = count("eval count")
        guard prompt != nil || output != nil else { return nil }
        return TokenUsage(input: prompt ?? 0, output: output ?? 0)
    }
}

/// Collects the usage of every CLI call made for one run. Shared with the reviewer's calls, which may run off the main actor.
public final class UsageMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: TokenUsage?
    /// A call whose CLI reported no usage: the total is then a lower bound.
    private var unreported = 0

    public init() {}

    public func add(_ usage: TokenUsage?) {
        lock.withLock {
            guard let usage else { unreported += 1; return }
            collected = collected.map { $0 + usage } ?? usage
        }
    }

    /// What the run used, or nil when no call reported anything. `complete` is false when some call didn't report.
    public var usage: TokenUsage? { lock.withLock { collected } }
    public var complete: Bool { lock.withLock { unreported == 0 } }
}

extension TokenUsage {
    /// "84k tokens", or "1.2M tokens".
    public static func formatted(_ tokens: Int) -> String {
        switch tokens {
        case ..<1000: "\(tokens)"
        case ..<10_000: String(format: "%.1fk", Double(tokens) / 1000)
        case ..<1_000_000: "\(Int((Double(tokens) / 1000).rounded()))k"
        default: String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
    }

    /// One line for a run card: "84k tokens (6k in, 2k out, 76k cached) · 2 passes".
    public var summary: String {
        var parts = ["\(Self.formatted(input)) in", "\(Self.formatted(output)) out"]
        if cacheRead + cacheWrite > 0 { parts.append("\(Self.formatted(cacheRead + cacheWrite)) cached") }
        return "\(Self.formatted(total)) tokens (\(parts.joined(separator: ", ")))" + (passes > 1 ? " · \(passes) passes" : "")
    }
}
