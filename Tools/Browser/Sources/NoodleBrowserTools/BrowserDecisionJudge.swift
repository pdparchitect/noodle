import BrowserBridge
import Foundation
import NoodleCore

/// What the decision model concluded from a page's settle signals, attached to
/// the tool result a bot sees. Every field is fail-open: no model, no field.
public struct BrowserActionJudgement: Codable, Equatable, Sendable {
    /// The gate reads ≥ 0.5 as settled.
    public var settledProbability: Float
    public var calibrated: Bool
    /// The gate's verdict, so a bot reads a boolean instead of re-gating.
    public var settled: Bool
    /// The blocker the page shows, judged only when overlay facts exist.
    public var blocker: String?
    public var blockerConfidence: Float?

    init(settledProbability: Float, calibrated: Bool, blocker: String? = nil, blockerConfidence: Float? = nil) {
        self.settledProbability = settledProbability; self.calibrated = calibrated
        self.settled = settledProbability >= DecisionGates.pass
        self.blocker = blocker; self.blockerConfidence = blockerConfidence
    }
}

/// Asks the chosen decision model the two browser questions whose answers save
/// the bot an inspect round-trip: did the page settle, and what blocks it. The
/// signals are code-computed facts; the model only weighs them.
public struct BrowserDecisionJudge: Sendable {
    /// The blocker vocabulary; `none` means the page is usable.
    public static let blockers = ["none", "cookie", "login", "captcha", "paywall", "age", "download"]
    private let serving: any DecisionModelServing

    public init(serving: any DecisionModelServing) {
        self.serving = serving
    }

    public func judge(_ signals: BrowserSettleSignals) async throws -> BrowserActionJudgement? {
        var questions: [String: DecisionQuestion] = [
            "settled": .noul(instructions: """
                The page's primary content finished rendering and stopped changing.
                Signals: readyState=\(signals.readyState), loading=\(signals.loading ?? false),
                mutations in the sampling window=\(signals.mutations ?? 0),
                visible spinners=\(signals.spinners ?? 0), unfinished resources=\(signals.activeResources ?? 0).
                Judge the signals only.
                """)
        ]
        let hasOverlay = signals.overlayText?.isEmpty == false
        if hasOverlay {
            questions["blocker"] = .choice(instructions: """
                The page shows one page-covering overlay. What kind of blocker is it?
                Overlay text: \(signals.overlayText ?? "").
                Vocabulary the overlay's identity and text match: \(signals.overlayMatches?.joined(separator: ", ") ?? "none").
                Page title: \(signals.title). URL: \(signals.url).
                """, criteria: Dictionary(uniqueKeysWithValues: Self.blockers.map {
                    ($0, Self.blockerDescriptions[$0] ?? "")
                }))
        }
        let answers = try await serving.decide(state: ["page": signals], questions: questions)
        guard let settled = answers["settled"]?.noul else { return nil }
        let blocker = hasOverlay ? answers["blocker"]?.choice : nil
        return BrowserActionJudgement(settledProbability: settled, calibrated: answers["settled"]?.calibrated ?? false,
                                      blocker: (blocker == "none") ? nil : blocker,
                                      blockerConfidence: answers["blocker"]?.confidence)
    }

    /// Done-verify for `present`: the page facts the card carries versus the
    /// message the person will read. Advises; it never blocks the handoff.
    public func verifyHandoff(title: String, url: String, message: String?) async throws -> BrowserHandoffCheck? {
        guard let message, !message.isEmpty else { return nil }
        let questions: [String: DecisionQuestion] = [
            "matches": .noul(instructions: """
                The page a person is handed shows what the accompanying message claims.
                Message: \(String(message.prefix(300))).
                Page title: \(String(title.prefix(200))). URL: \(url).
                Judge the page facts against the message only.
                """)
        ]
        let answers = try await serving.decide(state: ["handoff": ["title": title, "url": url]], questions: questions)
        guard let probability = answers["matches"]?.noul else { return nil }
        return BrowserHandoffCheck(matchProbability: probability, calibrated: answers["matches"]?.calibrated ?? false)
    }

    /// Screens untrusted page content before a bot reads it: does the text
    /// carry instructions aimed at an AI assistant? Returns P(injection).
    public func screen(_ text: String, source: String) async throws -> Float? {
        guard !text.isEmpty else { return nil }
        let questions: [String: DecisionQuestion] = [
            "injection": DecisionQuestions.injection(content: text, source: source, webPage: true)]
        let answers = try await serving.decide(state: ["content": ["source": source]], questions: questions)
        return answers["injection"]?.noul
    }

    private static let blockerDescriptions: [String: String] = [
        "none": "The overlay is dismissible decoration; the page is usable.",
        "cookie": "A cookie or consent notice asking for acceptance.",
        "login": "A sign-in or account wall before the content.",
        "captcha": "A human-verification challenge.",
        "paywall": "A subscription or payment demand.",
        "age": "An age confirmation gate.",
        "download": "An app-download nudge covering the page.",
    ]
}

/// The `present` done-verify result: does the handed-over page match what the
/// message claims? An advice field on the card, never a gate.
public struct BrowserHandoffCheck: Codable, Equatable, Sendable {
    public var matchProbability: Float
    public var matches: Bool
    public var calibrated: Bool

    init(matchProbability: Float, calibrated: Bool) {
        self.matchProbability = matchProbability; self.calibrated = calibrated
        self.matches = matchProbability >= DecisionGates.pass
    }
}

/// The decision-model seam the provider asks its two questions through: the
/// settle judgement after actions, and the handoff check before present.
public struct BrowserJudgeServing: Sendable {
    private let settleCall: @Sendable (BrowserSettleSignals) async -> BrowserActionJudgement?
    private let handoffCall: @Sendable (_ title: String, _ url: String, _ message: String?) async -> BrowserHandoffCheck?
    private let screenCall: @Sendable (_ text: String, _ source: String) async -> Float?

    public init(settle: @escaping @Sendable (BrowserSettleSignals) async -> BrowserActionJudgement? = { _ in nil },
                handoff: @escaping @Sendable (_ title: String, _ url: String, _ message: String?) async -> BrowserHandoffCheck? = { _, _, _ in nil },
                screen: @escaping @Sendable (_ text: String, _ source: String) async -> Float? = { _, _ in nil }) {
        self.settleCall = settle; self.handoffCall = handoff; self.screenCall = screen
    }

    public func settle(_ signals: BrowserSettleSignals) async -> BrowserActionJudgement? {
        await settleCall(signals)
    }

    public func handoff(title: String, url: String, message: String?) async -> BrowserHandoffCheck? {
        await handoffCall(title, url, message)
    }

    public func screen(_ text: String, source: String) async -> Float? {
        await screenCall(text, source)
    }
}

/// The browser questions asked through the shared serving cache, so settings
/// changes and failures re-resolve without a restart.
extension DecisionModelServingCache {
    nonisolated public func browserServing() -> BrowserJudgeServing {
        BrowserJudgeServing(
            settle: { signals in await self.call { try await BrowserDecisionJudge(serving: $0).judge(signals) } },
            handoff: { title, url, message in await self.call { try await BrowserDecisionJudge(serving: $0).verifyHandoff(title: title, url: url, message: message) } },
            screen: { text, source in await self.call { try await BrowserDecisionJudge(serving: $0).screen(text, source: source) } })
    }
}
