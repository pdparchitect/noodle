import Foundation
import NoodleCore

public struct UsageReading: Equatable, Sendable {
    public var model: String
    public var tokens: UsageTokens
    public var costUSD: Double?
}

/// Turns one runtime's raw harness messages into per-call usage. Harnesses that
/// do not report usage produce nothing.
struct UsageMeter {
    private struct ClaudeTotals {
        var tokens = UsageTokens()
        var cost = 0.0
    }

    /// Claude's modelUsage and cost grow for the life of the process.
    private var claudeTotals: [String: ClaudeTotals] = [:]

    mutating func readings(_ message: [String: Any], provider: HarnessProvider) -> [UsageReading] {
        switch provider {
        case .claudeCode: return claude(message)
        case .codex: return codex(message).map { [$0] } ?? []
        case .fx, .grokBuild, .openCode, .apple: return acp(message).map { [$0] } ?? []
        case .muse, .antigravity: return []
        }
    }

    private mutating func claude(_ message: [String: Any]) -> [UsageReading] {
        guard message["type"] as? String == "result",
              let models = message["modelUsage"] as? [String: [String: Any]] else { return [] }
        return models.keys.sorted().compactMap { key in
            let usage = models[key] ?? [:]
            let current = ClaudeTotals(tokens: UsageTokens(input: Self.int(usage["inputTokens"]),
                output: Self.int(usage["outputTokens"]), cacheRead: Self.int(usage["cacheReadInputTokens"]),
                cacheWrite: Self.int(usage["cacheCreationInputTokens"]), reasoning: Self.int(usage["thinkingTokens"])),
                cost: usage["costUSD"] as? Double ?? 0)
            var previous = claudeTotals[key] ?? ClaudeTotals()
            claudeTotals[key] = current
            // A smaller total means Claude started counting again.
            if current.tokens.total < previous.tokens.total || current.cost < previous.cost { previous = ClaudeTotals() }
            let tokens = UsageTokens(input: current.tokens.input - previous.tokens.input,
                output: current.tokens.output - previous.tokens.output,
                cacheRead: current.tokens.cacheRead - previous.tokens.cacheRead,
                cacheWrite: current.tokens.cacheWrite - previous.tokens.cacheWrite,
                reasoning: max(0, current.tokens.reasoning - previous.tokens.reasoning))
            let cost = current.cost - previous.cost
            guard tokens.total > 0 || cost > 0 else { return nil }
            return UsageReading(model: usage["canonicalModel"] as? String ?? key, tokens: tokens, costUSD: cost)
        }
    }

    /// `last` is one model call. Its input includes the cached tokens.
    private func codex(_ message: [String: Any]) -> UsageReading? {
        guard message["method"] as? String == "thread/tokenUsage/updated",
              let params = message["params"] as? [String: Any],
              let last = (params["tokenUsage"] as? [String: Any])?["last"] as? [String: Any] else { return nil }
        let cached = Self.int(last["cachedInputTokens"]), written = Self.int(last["cacheWriteInputTokens"])
        let tokens = UsageTokens(input: max(0, Self.int(last["inputTokens"]) - cached - written),
            output: Self.int(last["outputTokens"]), cacheRead: cached, cacheWrite: written,
            reasoning: Self.int(last["reasoningOutputTokens"]))
        guard tokens.total > 0 else { return nil }
        return UsageReading(model: params["model"] as? String ?? "", tokens: tokens, costUSD: nil)
    }

    /// The prompt response's usage covers one turn. The session cost in
    /// usage_update is cumulative and not re-sent after a resume, so it is not used.
    private func acp(_ message: [String: Any]) -> UsageReading? {
        guard message["method"] == nil,
              let usage = (message["result"] as? [String: Any])?["usage"] as? [String: Any] else { return nil }
        let tokens = UsageTokens(input: Self.int(usage["inputTokens"]), output: Self.int(usage["outputTokens"]),
            cacheRead: Self.int(usage["cachedReadTokens"]), cacheWrite: Self.int(usage["cachedWriteTokens"]),
            reasoning: Self.int(usage["thoughtTokens"]))
        guard tokens.total > 0 else { return nil }
        return UsageReading(model: message["model"] as? String ?? "", tokens: tokens, costUSD: nil)
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
