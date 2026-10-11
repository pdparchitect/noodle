import ComputerBridge
import Foundation
import NoodleCore

/// What the decision model concluded from a terminal tail, attached to the
/// terminal-read result a bot sees. Every field is fail-open: no model, no field.
public struct ComputerCommandStatus: Codable, Equatable, Sendable {
    public var status: String
    public var confidence: Float?
    public var calibrated: Bool

    init(status: String, confidence: Float? = nil, calibrated: Bool) {
        self.status = status; self.confidence = confidence; self.calibrated = calibrated
    }
}

/// The done-verify for computer `preview`: does the handed-over view match what
/// the message claims? Advises; it never blocks the handoff.
public struct ComputerHandoffCheck: Codable, Equatable, Sendable {
    public var matchProbability: Float
    public var matches: Bool
    public var calibrated: Bool

    init(matchProbability: Float, calibrated: Bool) {
        self.matchProbability = matchProbability; self.calibrated = calibrated; self.matches = matchProbability >= DecisionGates.pass
    }
}

/// The desktop-readiness verdict over a preview image plus the code heuristic,
/// so a bot knows a desktop finished starting instead of guessing from a frame.
public struct ComputerReadinessCheck: Codable, Equatable, Sendable {
    public var readyProbability: Float
    public var ready: Bool
    public var calibrated: Bool

    init(readyProbability: Float, calibrated: Bool) {
        self.readyProbability = readyProbability; self.calibrated = calibrated; self.ready = readyProbability >= DecisionGates.pass
    }
}

/// Asks the chosen decision model the computer questions whose answers save the
/// bot a read-and-guess round-trip. Code-computed facts ride along; the model
/// only weighs them.
public struct ComputerDecisionJudge: Sendable {
    /// The status vocabulary; `waiting_for_input` means the command wants the person or bot to answer.
    public static let statuses = ["succeeded", "failed", "waiting_for_input"]
    private let serving: any DecisionModelServing

    public init(serving: any DecisionModelServing) {
        self.serving = serving
    }

    /// Reads a terminal tail and names the state the command is in.
    public func status(tail: String, exited: Bool) async throws -> ComputerCommandStatus? {
        guard !tail.isEmpty || exited else { return nil }
        let questions: [String: DecisionQuestion] = [
            "status": .choice(instructions: """
                A shell command's newest output says which state the command is in.
                Shell exited: \(exited).
                Output tail: \(String(tail.suffix(DecisionGates.tailCap))).
                Judge the output only; a prompt without an error is success.
                """, criteria: Dictionary(uniqueKeysWithValues: Self.statuses.map {
                    ($0, Self.statusDescriptions[$0] ?? "")
                }))
        ]
        let answers = try await serving.decide(state: ["terminal": ["exited": exited]], questions: questions)
        guard let choice = answers["status"]?.choice else { return nil }
        return ComputerCommandStatus(status: choice, confidence: answers["status"]?.confidence, calibrated: answers["status"]?.calibrated ?? false)
    }

    /// Done-verify for `preview`: the view facts the card carries versus the
    /// message the person will read. Advises; it never blocks the handoff.
    public func verifyHandoff(computer: String, view: String, preview: String, message: String?) async throws -> ComputerHandoffCheck? {
        guard let message, !message.isEmpty else { return nil }
        let questions: [String: DecisionQuestion] = [
            "matches": .noul(instructions: """
                The computer view a person is handed shows what the accompanying message claims.
                Message: \(String(message.prefix(300))).
                Computer: \(computer). View: \(view).
                Terminal preview: \(String(preview.prefix(400))).
                Judge the view facts against the message only.
                """)
        ]
        let answers = try await serving.decide(state: ["handoff": ["computer": computer, "view": view]], questions: questions)
        guard let noul = answers["matches"]?.noul else { return nil }
        return ComputerHandoffCheck(matchProbability: noul, calibrated: answers["matches"]?.calibrated ?? false)
    }

    /// Desktop readiness from the picture plus the code heuristic that already
    /// rejected empty frames: is this desktop ready for work?
    public func readiness(image: DecisionImage, codeSaysUseful: Bool) async throws -> ComputerReadinessCheck? {
        let questions: [String: DecisionQuestion] = [
            "ready": .noul(instructions: """
                The desktop finished starting and is ready for agent work: apps loaded,
                no boot or login screen, no single loading spinner occupying the view.
                The pixel heuristic called the frame \(codeSaysUseful ? "useful" : "not useful").
                """)
        ]
        let answers = try await serving.decide(state: ["preview": image, "heuristic": ["useful": codeSaysUseful]], questions: questions)
        guard let noul = answers["ready"]?.noul else { return nil }
        return ComputerReadinessCheck(readyProbability: noul, calibrated: answers["ready"]?.calibrated ?? false)
    }

    /// Screens untrusted terminal or downloaded content before a bot reads it:
    /// does the text carry instructions aimed at an AI assistant? Returns P(injection).
    public func screen(_ text: String, source: String) async throws -> Float? {
        guard !text.isEmpty else { return nil }
        let questions: [String: DecisionQuestion] = [
            "injection": DecisionQuestions.injection(content: text, source: source, webPage: false)
        ]
        let answers = try await serving.decide(state: ["content": ["source": source]], questions: questions)
        return answers["injection"]?.noul
    }

    private static let statusDescriptions: [String: String] = [
        "succeeded": "Output ends at a shell prompt, or clean completion, with no error text.",
        "failed": "Output reports an error, non-zero exit, or traceback.",
        "waiting_for_input": "The command asks a question and waits: confirmation, password, 2FA, or menu choice.",
    ]
}

/// The decision-model seam the computer provider asks its questions through.
public struct ComputerJudgeServing: Sendable {
    private let statusCall: @Sendable (_ tail: String, _ exited: Bool) async -> ComputerCommandStatus?
    private let handoffCall: @Sendable (_ computer: String, _ view: String, _ preview: String, _ message: String?) async -> ComputerHandoffCheck?
    private let readinessCall: @Sendable (_ image: DecisionImage, _ codeSaysUseful: Bool) async -> ComputerReadinessCheck?
    private let screenCall: @Sendable (_ text: String, _ source: String) async -> Float?

    public init(status: @escaping @Sendable (_ tail: String, _ exited: Bool) async -> ComputerCommandStatus? = { _, _ in nil },
                handoff: @escaping @Sendable (_ computer: String, _ view: String, _ preview: String, _ message: String?) async -> ComputerHandoffCheck? = { _, _, _, _ in nil },
                readiness: @escaping @Sendable (_ image: DecisionImage, _ codeSaysUseful: Bool) async -> ComputerReadinessCheck? = { _, _ in nil },
                screen: @escaping @Sendable (_ text: String, _ source: String) async -> Float? = { _, _ in nil }) {
        self.statusCall = status; self.handoffCall = handoff; self.readinessCall = readiness; self.screenCall = screen
    }

    public func status(tail: String, exited: Bool) async -> ComputerCommandStatus? {
        await statusCall(tail, exited)
    }

    public func handoff(computer: String, view: String, preview: String, message: String?) async -> ComputerHandoffCheck? {
        await handoffCall(computer, view, preview, message)
    }

    public func readiness(image: DecisionImage, codeSaysUseful: Bool) async -> ComputerReadinessCheck? {
        await readinessCall(image, codeSaysUseful)
    }

    public func screen(_ text: String, source: String) async -> Float? {
        await screenCall(text, source)
    }
}


/// The computer questions asked through the shared serving cache, so settings
/// changes and failures re-resolve without a restart.
extension DecisionModelServingCache {
    nonisolated public func computerServing() -> ComputerJudgeServing {
        ComputerJudgeServing(
            status: { tail, exited in await self.call { try await ComputerDecisionJudge(serving: $0).status(tail: tail, exited: exited) } },
            handoff: { computer, view, preview, message in await self.call { try await ComputerDecisionJudge(serving: $0).verifyHandoff(computer: computer, view: view, preview: preview, message: message) } },
            readiness: { image, useful in await self.call { try await ComputerDecisionJudge(serving: $0).readiness(image: image, codeSaysUseful: useful) } },
            screen: { text, source in await self.call { try await ComputerDecisionJudge(serving: $0).screen(text, source: source) } })
    }
}
