import Foundation

/// Asks the Hub to call one of the user's bots. The device captures and plays the audio, which
/// goes up and down the call's channel as `LinkCallAudio`; the Hub connects it to the bot's voice.
public struct LinkCallStart: Codable, Equatable, Sendable {
    public var conversationID: UUID
    /// The call the bot placed that this answers, as `callRinging` named it. Nil when the person calls.
    public var answering: UUID?

    public init(conversationID: UUID, answering: UUID? = nil) {
        self.conversationID = conversationID
        self.answering = answering
    }
}

/// A call one of the user's bots placed, ringing on their devices. Nothing connects to the bot's voice
/// until a device answers it with `startCall`.
public struct LinkIncomingCall: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var botID: UUID
    /// The bot's conversation with the user, where the call is answered or left as missed.
    public var conversationID: UUID
    /// Why the bot is calling.
    public var reason: String
    /// How long it rings on from when the Hub sent it before it counts as missed. Seconds left rather than a
    /// time, so a device whose clock is off rings as long as the Hub.
    public var secondsLeft: TimeInterval

    public init(id: UUID, botID: UUID, conversationID: UUID, reason: String, secondsLeft: TimeInterval) {
        self.id = id; self.botID = botID; self.conversationID = conversationID; self.reason = reason; self.secondsLeft = secondsLeft
    }

    private enum CodingKeys: String, CodingKey { case id, botID, conversationID, reason, secondsLeft, expiresAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        botID = try c.decode(UUID.self, forKey: .botID)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        reason = try c.decode(.reason, or: "")
        // Hubs that sent a time instead are read as well as this device's clock allows.
        if let seconds = try c.decodeIfPresent(TimeInterval.self, forKey: .secondsLeft) { secondsLeft = seconds }
        else if let expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt) { secondsLeft = expiresAt.timeIntervalSinceNow }
        else { secondsLeft = 45 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(botID, forKey: .botID)
        try c.encode(conversationID, forKey: .conversationID)
        try c.encode(reason, forKey: .reason)
        try c.encode(secondsLeft, forKey: .secondsLeft)
    }
}

/// How a call a bot placed ended without being answered.
public enum LinkUnansweredCall: String, Codable, Equatable, Sendable { case missed, declined }

public struct LinkCallLine: Codable, Equatable, Sendable {
    public enum Speaker: String, Codable, Sendable { case you, bot }

    public var speaker: Speaker
    public var text: String
    /// When it was said, so it can be shown among what was typed during the call.
    public var at: Date?

    public init(speaker: Speaker, text: String, at: Date?) {
        self.speaker = speaker
        self.text = text
        self.at = at
    }
}

/// A call as its conversation shows it, on the message that marks where it started.
public struct LinkCallRecord: Codable, Equatable, Sendable {
    public var botID: UUID
    /// Nil while the call is on.
    public var endedAt: Date?
    public var lines: [LinkCallLine]
    /// Set for a call the bot placed that nobody answered. Nil from older Hubs, whose cards are all calls that happened.
    public var unanswered: LinkUnansweredCall?
    /// Why the bot called, for a call it placed.
    public var reason: String?

    public init(botID: UUID, endedAt: Date? = nil, lines: [LinkCallLine] = [], unanswered: LinkUnansweredCall? = nil, reason: String? = nil) {
        self.botID = botID
        self.endedAt = endedAt
        self.lines = lines
        self.unanswered = unanswered
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case botID, endedAt, lines, unanswered, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        botID = try c.decode(UUID.self, forKey: .botID)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        lines = try c.decode(.lines, or: [])
        // A kind of unanswered call a later Hub adds reads as missed.
        unanswered = try c.decodeIfPresent(String.self, forKey: .unanswered).map { LinkUnansweredCall(rawValue: $0) ?? .missed }
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// A voice a bot on a harness can speak with on calls.
public struct LinkCallVoice: Codable, Hashable, Identifiable, Sendable {
    public enum Presentation: String, Codable, Sendable { case feminine, masculine }

    public var id: String
    public var name: String
    public var presentation: Presentation

    public init(id: String, name: String, presentation: Presentation) {
        self.id = id
        self.name = name
        self.presentation = presentation
    }
}

/// What comes down a call's channel, one JSON frame each, among the audio. Closing the channel hangs up.
public enum LinkCallEvent: Codable, Equatable, Sendable {
    case started
    case line(LinkCallLine)
    /// The detail is nil when the call ended without an error.
    case ended(String?)

    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public init?(_ frame: Data) {
        guard let event = try? JSONDecoder().decode(Self.self, from: frame) else { return nil }
        self = event
    }
}

/// A call's audio, both ways on its channel: the person's voice up, the bot's down. Each frame is
/// one Opus packet of 20 ms at 48 kHz mono, behind a zero byte, which no JSON event starts with.
public enum LinkCallAudio {
    public static let sampleRate = 48_000
    public static let frameSamples = 960

    public static func frame(_ packet: Data) -> Data { Data([0]) + packet }

    public static func packet(in frame: Data) -> Data? {
        guard frame.first == 0 else { return nil }
        return frame.dropFirst()
    }
}
