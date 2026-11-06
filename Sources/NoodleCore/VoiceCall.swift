import Foundation
import ProductIdentity

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
    /// Set for a call the bot placed that nobody answered; its card then stands for a missed call.
    public var unanswered: UnansweredCall?
    /// Why the bot called, for a call it placed.
    public var reason: String?

    public init(agentID: UUID, endedAt: Date? = nil, lines: [VoiceCallLine] = [],
                unanswered: UnansweredCall? = nil, reason: String? = nil) {
        self.agentID = agentID
        self.endedAt = endedAt
        self.lines = lines
        self.unanswered = unanswered
        self.reason = reason
    }
}

/// Who the bot is. Codex answers small talk on a call with a voice model of its own,
/// which does not read the bot's AGENTS.md.
public struct VoiceCallIdentity: Hashable, Sendable {
    public var name: String
    public var description: String?
    public var backstory: String

    public init(name: String, description: String?, backstory: String) {
        self.name = name
        self.description = description
        self.backstory = backstory
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
    /// Nil leaves the voice to introduce itself as the harness does.
    public var identity: VoiceCallIdentity?
    /// Recent conversation lines, oldest first, so the call starts with context.
    public var recentLines: [VoiceCallLine]
    /// Why the bot called, when the person answered a call the bot placed.
    public var answeredCallReason: String?

    public init(offer: String, voice: String?, conversationID: UUID, personName: String,
                identity: VoiceCallIdentity? = nil, recentLines: [VoiceCallLine] = [], answeredCallReason: String? = nil) {
        self.offer = offer
        self.voice = voice
        self.conversationID = conversationID
        self.personName = personName
        self.identity = identity
        self.recentLines = recentLines
        self.answeredCallReason = answeredCallReason
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
    public static func startInstructions(conversationID: UUID, personName: String, answeredCallReason: String? = nil) -> String {
        let start = answeredCallReason.map {
            "\(personName) answered the voice call you placed from \(ProductIdentity.current.name) conversation \(conversationID.uuidString.lowercased()). You called about: \($0). Start by saying why you called."
        } ?? "\(personName) started a voice call with you from \(ProductIdentity.current.name) conversation \(conversationID.uuidString.lowercased())."
        return """
        \(start) Requests spoken on the call arrive here directly, not through Messenger. Your final message for a spoken request is read aloud on the call, so keep it brief and conversational, without Markdown, lists, links or code. During the call \(personName) may also type messages or share files in that conversation; they arrive through Messenger as usual and belong to the same discussion. Send files, links and anything that is better read than heard to the conversation through Messenger, and mention on the call that you sent them.
        """
    }

    /// Given to the voice before anything is said, so it speaks as the bot.
    public static func identity(_ identity: VoiceCallIdentity) -> String {
        var sections = ["You are \(identity.name). Introduce yourself as \(identity.name) and speak as them throughout the call."]
        if let description = identity.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            sections.append("Description:\n\(description)")
        }
        let backstory = identity.backstory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !backstory.isEmpty { sections.append("Backstory:\n\(backstory)") }
        return sections.joined(separator: "\n\n")
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
