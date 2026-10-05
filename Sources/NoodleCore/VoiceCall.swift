import Foundation

public enum VoiceCallSpeaker: String, Codable, Hashable, Sendable {
    case person, bot
}

public struct VoiceCallLine: Codable, Hashable, Sendable {
    public var speaker: VoiceCallSpeaker
    public var text: String
    /// When it was said, so it can be shown among what was typed during the call.
    public var at: Date?

    public init(_ speaker: VoiceCallSpeaker, _ text: String, at: Date? = nil) {
        self.speaker = speaker
        self.text = text
        self.at = at
    }
}

/// A call as its conversation shows it. It is never delivered to the bot, which
/// heard the call itself.
public struct VoiceCallRecord: Codable, Hashable, Sendable {
    public var agentID: UUID
    /// Nil while the call is on, or when Noodle quit during it.
    public var endedAt: Date?
    public var lines: [VoiceCallLine]

    public init(agentID: UUID, endedAt: Date? = nil, lines: [VoiceCallLine] = []) {
        self.agentID = agentID
        self.endedAt = endedAt
        self.lines = lines
    }
}

/// Media is negotiated with WebRTC: the app captures and plays audio, the runtime
/// only relays the session description.
public struct VoiceCallRequest: Sendable {
    public var offer: String
    /// Nil leaves the voice to the harness.
    public var voice: String?
    public var conversationID: UUID
    public var personName: String
    /// Recent conversation lines, oldest first, so the call starts with context.
    public var recentLines: [VoiceCallLine]

    public init(offer: String, voice: String?, conversationID: UUID, personName: String, recentLines: [VoiceCallLine] = []) {
        self.offer = offer
        self.voice = voice
        self.conversationID = conversationID
        self.personName = personName
        self.recentLines = recentLines
    }
}

public enum VoiceCallEvent: Equatable, Sendable {
    case answer(String)
    case started
    case line(VoiceCallLine)
    /// The detail is nil when the call ended without an error.
    case ended(String?)
}

public struct VoiceCallUnavailable: LocalizedError {
    public init() {}
    public var errorDescription: String? { "This bot cannot take calls right now." }
}

public enum VoiceCallDocumentation {
    /// Given to the bot when a call starts. Spoken requests arrive in its own
    /// thread rather than through Messenger, so it needs to know where they come from.
    public static func startInstructions(conversationID: UUID, personName: String) -> String {
        """
        \(personName) started a voice call with you from Noodle conversation \(conversationID.uuidString.lowercased()). Requests spoken on the call arrive here directly, not through Messenger. Your final message for a spoken request is read aloud on the call, so keep it brief and conversational, without Markdown, lists, links or code. During the call \(personName) may also type messages or share files in that conversation; they arrive through Messenger as usual and belong to the same discussion. Send files, links and anything that is better read than heard to the conversation through Messenger, and mention on the call that you sent them.
        """
    }

    public static let endInstructions = "The voice call has ended. Answer later requests through Messenger as usual."

    /// How a message sent in the chat during a call is passed to the voice.
    public static func typedMessage(body: String, attachmentNames: [String]) -> String {
        var lines = ["Sent in the conversation during the call:"]
        if !body.isEmpty { lines.append(body) }
        if !attachmentNames.isEmpty { lines.append("Shared files: " + attachmentNames.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}

public enum VoicePresentation: String, Codable, Hashable, Sendable {
    case feminine, masculine
}

public struct HarnessVoice: Hashable, Sendable {
    public let id: String
    public let presentation: VoicePresentation
    public var name: String { id.capitalized }
}

extension HarnessProvider {
    /// The voices a bot can speak with on calls. A harness with none cannot take calls.
    /// Codex does not say how its voices sound, so each was sorted once by its measured
    /// pitch: about 175–240 Hz for the feminine ones, 90–155 Hz for the masculine ones.
    public var voices: [HarnessVoice] {
        switch self {
        case .codex:
            ["juniper", "maple", "sol", "vale"].map { HarnessVoice(id: $0, presentation: .feminine) }
                + ["arbor", "breeze", "cove", "ember", "spruce"].map { HarnessVoice(id: $0, presentation: .masculine) }
        case .claudeCode, .muse, .grokBuild, .fx, .openCode, .antigravity, .apple:
            []
        }
    }

    /// Nil leaves the choice to the harness.
    public func defaultVoice(for presentation: VoicePresentation?) -> String? {
        switch (self, presentation) {
        case (.codex, .feminine): "juniper"
        case (.codex, .masculine): "cove"
        default: nil
        }
    }
}
