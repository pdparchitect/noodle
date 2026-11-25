import Foundation
import NoodleCore

public struct UsageReading: Equatable, Sendable {
    public var model: String
    public var tokens: UsageTokens
    public var costUSD: Double?
    public var session: String? = nil
}

/// Turns one runtime's raw harness messages into per-call usage. Harnesses that
/// do not report usage produce nothing.
struct UsageMeter {
    /// Claude's modelUsage and cost grow for the life of the process, and a
    /// resumed session starts again from its totals before the restart.
    private var claudeTotals: [String: UsageTotal] = [:]

    /// `recorded` gives what the ledger already holds for a session, per model.
    mutating func readings(_ message: [String: Any], provider: HarnessProvider,
                           recorded: (String) -> [String: UsageTotal] = { _ in [:] }) -> [UsageReading] {
        switch provider {
        case .claudeCode: return claude(message, recorded: recorded)
        case .codex: return codex(message).map { [$0] } ?? []
        case .fx, .grokBuild, .openCode, .copilot, .apple: return acp(message).map { [$0] } ?? []
        case .muse, .antigravity: return []
        }
    }

    private mutating func claude(_ message: [String: Any], recorded: (String) -> [String: UsageTotal]) -> [UsageReading] {
        guard message["type"] as? String == "result",
              let models = message["modelUsage"] as? [String: [String: Any]] else { return [] }
        let session = message["session_id"] as? String
        var restored: [String: UsageTotal]?
        return models.keys.sorted().compactMap { key in
            let usage = models[key] ?? [:]
            let model = usage["canonicalModel"] as? String ?? key
            let current = UsageTotal(tokens: UsageTokens(input: Self.int(usage["inputTokens"]),
                output: Self.int(usage["outputTokens"]), cacheRead: Self.int(usage["cacheReadInputTokens"]),
                cacheWrite: Self.int(usage["cacheCreationInputTokens"]), reasoning: Self.int(usage["thinkingTokens"])),
                costUSD: usage["costUSD"] as? Double ?? 0)
            var previous = claudeTotals[key] ?? UsageTotal()
            if claudeTotals[key] == nil, let session {
                if restored == nil { restored = recorded(session) }
                previous = restored?[model] ?? UsageTotal()
            }
            claudeTotals[key] = current
            // A smaller total means Claude started counting again. Recorded
            // cost is a sum of differences, so it may exceed the total slightly.
            let (now, then) = (current.tokens, previous.tokens)
            if now.input < then.input || now.output < then.output || now.cacheRead < then.cacheRead
                || now.cacheWrite < then.cacheWrite || current.costUSD < previous.costUSD - 1e-9 {
                previous = UsageTotal()
            }
            let tokens = UsageTokens(input: now.input - previous.tokens.input,
                output: now.output - previous.tokens.output,
                cacheRead: now.cacheRead - previous.tokens.cacheRead,
                cacheWrite: now.cacheWrite - previous.tokens.cacheWrite,
                reasoning: max(0, now.reasoning - previous.tokens.reasoning))
            let cost = max(0, current.costUSD - previous.costUSD)
            guard tokens.total > 0 || cost > 0 else { return nil }
            return UsageReading(model: model, tokens: tokens, costUSD: cost, session: session)
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
