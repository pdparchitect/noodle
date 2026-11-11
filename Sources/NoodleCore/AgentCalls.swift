#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A call a bot placed to its person with `messenger --call`. It rings where the bot runs
/// until the person answers or declines it, or until it expires; nothing connects to the
/// bot's voice before it is answered.
public struct AgentCallRequest: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let agentID: UUID
    /// The bot's own conversation with its person, where a missed call leaves its card.
    public let conversationID: UUID
    /// Why the bot is calling, shown while it rings.
    public let reason: String
    public let requestedAt: Date
    /// When ringing stops and the call counts as missed.
    public let expiresAt: Date

    public init(id: UUID = UUID(), agentID: UUID, conversationID: UUID, reason: String, requestedAt: Date, expiresAt: Date) {
        self.id = id; self.agentID = agentID; self.conversationID = conversationID
        self.reason = reason; self.requestedAt = requestedAt; self.expiresAt = expiresAt
    }
}

extension AgentCallRequest {
    /// The reason as one line, as shown while the call rings. Control and format characters go, such as
    /// line breaks, bidirectional overrides and zero-width ones, so it reads as the bot wrote it.
    static func shownReason(_ raw: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: kept.append(" ")
            case .format: continue
            default: kept.append(scalar)
            }
        }
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// How a call a bot placed ended without being answered.
public enum UnansweredCall: String, Codable, Hashable, Sendable {
    case missed, declined
}

/// Limits that keep a bot from ringing its person again and again unprompted.
public enum AgentCallLimits {
    /// How long a call rings before it counts as missed.
    public static let ringing: TimeInterval = 45
    /// The shortest time between one call and the next, whatever became of the first.
    public static let cooldown: TimeInterval = 30 * 60
    /// Calls a bot may place in any 24 hours.
    public static let perDay = 3
    /// A call placed this soon after the person wrote in the bot's conversation, and after the bot's
    /// last call, counts as asked for: the cooldown and the daily limit do not hold it back.
    public static let askedWithin: TimeInterval = 5 * 60
    public static let reasonLength = 200
}

struct AgentCallError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

/// Kept beside agent.json, outside the workspace, so the bot reaches it only through Messenger.
private struct AgentCallState: Codable {
    var pending: AgentCallRequest?
    /// When the bot placed its recent calls, for the cooldown and the daily limit.
    var placed: [Date] = []
}

public enum AgentCallDocumentation {
    /// Left for the bot when its call was not answered, so it can follow up in writing.
    public static func unansweredNote(_ outcome: UnansweredCall, personName: String, reason: String, conversationID: UUID) -> String {
        let what = outcome == .declined ? "\(personName) declined your call" : "\(personName) did not answer your call"
        return "\(what) about: \(reason). If it still matters, write to them in conversation \(conversationID.uuidString.lowercased()) instead; do not call again for the same thing."
    }
}

extension WorkspaceRepository {
    /// Places a call from a bot whose harness takes calls to the person in its own conversation.
    public func requestCall(agentID: UUID, reason rawReason: String, now: Date = Date()) throws -> AgentCallRequest {
        let reason = AgentCallRequest.shownReason(rawReason)
        guard !reason.isEmpty, reason.unicodeScalars.count <= AgentCallLimits.reasonLength else {
            throw AgentCallError("A call needs a --reason of at most \(AgentCallLimits.reasonLength) characters saying why you are calling.")
        }
        guard let agent = try loadAgents().first(where: { $0.id == agentID }), agent.archivedAt == nil else {
            throw WorkspaceError.missingAgent(agentID)
        }
        guard HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.voices.isEmpty == false else {
            throw AgentCallError("Your harness cannot take voice calls, so you cannot call. Send a message instead.")
        }
        guard let conversation = try loadConversations().first(where: {
            $0.kind == .direct && $0.guest == nil && $0.participantIDs == [agentID]
        }) else { throw AgentCallError("You have no conversation of your own with your person to call from.") }
        return try updateCalls(agentID: agentID) { state in
            if let pending = state.pending, pending.expiresAt > now {
                throw AgentCallError("Your call is still ringing. Wait for it to be answered, declined or missed.")
            }
            state.placed.removeAll { now.timeIntervalSince($0) >= 24 * 60 * 60 }
            let last = state.placed.max()
            if try !personAskedForCall(in: conversation.id, since: last, now: now) {
                let asked = "If they write to you asking for a call, you can call within \(Int(AgentCallLimits.askedWithin / 60)) minutes of their message."
                if let last, now.timeIntervalSince(last) < AgentCallLimits.cooldown {
                    let minutes = Int((AgentCallLimits.cooldown - now.timeIntervalSince(last)) / 60) + 1
                    throw AgentCallError("You called less than \(Int(AgentCallLimits.cooldown / 60)) minutes ago. Send a message instead, or call again in \(minutes) minutes if it is still urgent. \(asked)")
                }
                guard state.placed.count < AgentCallLimits.perDay else {
                    throw AgentCallError("You have called \(AgentCallLimits.perDay) times in the last 24 hours. Send a message instead. \(asked)")
                }
            }
            let requestedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            let request = AgentCallRequest(agentID: agentID, conversationID: conversation.id, reason: reason,
                                           requestedAt: requestedAt, expiresAt: requestedAt.addingTimeInterval(AgentCallLimits.ringing))
            state.pending = request
            state.placed.append(requestedAt)
            return request
        }
    }

    /// Whether the person wrote in the bot's conversation in the last few minutes and after its last call,
    /// so one message asks for one call. Messages from the bot itself or Noodle do not count.
    private func personAskedForCall(in conversationID: UUID, since lastCall: Date?, now: Date) throws -> Bool {
        let earliest = max(now.addingTimeInterval(-AgentCallLimits.askedWithin), lastCall ?? .distantPast)
        return try loadMessages(conversationID: conversationID).reversed().contains {
            $0.author == .user && $0.call == nil && $0.createdAt > earliest
        }
    }

    /// The call the bot placed that has not been answered, declined or missed yet, including one
    /// that expired while nobody was there to end it.
    public func pendingCall(agentID: UUID) -> AgentCallRequest? {
        (try? readCalls(agentID: agentID))?.pending
    }

    /// Ends the bot's pending call. Returns it only when it was still pending, so one call ends once.
    public func endCall(agentID: UUID, id: UUID) throws -> AgentCallRequest? {
        try updateCalls(agentID: agentID) { state in
            guard let pending = state.pending, pending.id == id else { return nil }
            state.pending = nil
            return pending
        }
    }

    /// Leaves a card for a call nobody answered in the bot's conversation. It comes from the bot,
    /// so the conversation shows it unread, and like every call card it never reaches the bot's inbox.
    @discardableResult
    public func recordUnansweredCall(_ request: AgentCallRequest, _ outcome: UnansweredCall, at now: Date = Date()) throws -> ChatMessage {
        guard var conversation = try loadConversations().first(where: { $0.id == request.conversationID }),
              conversation.participantIDs.contains(request.agentID) else {
            throw WorkspaceError.missingConversation(request.conversationID)
        }
        var message = ChatMessage(conversationID: conversation.id, author: .agent(request.agentID),
                                  body: outcome == .declined ? "Declined call" : "Missed call", createdAt: now, delivery: .delivered)
        message.call = VoiceCallRecord(agentID: request.agentID, endedAt: now, unanswered: outcome, reason: request.reason)
        try append(message)
        conversation.updatedAt = now
        try updateConversation(conversation)
        return message
    }

    private func callsURL(agentID: UUID) -> URL { storage(for: agentID).package.appendingPathComponent("calls.json") }

    private func readCalls(agentID: UUID) throws -> AgentCallState {
        let url = callsURL(agentID: agentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return AgentCallState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentCallState.self, from: Data(contentsOf: url))
    }

    /// Messenger and the app change the file from different threads, so changes take a lock.
    private func updateCalls<Value>(agentID: UUID, _ change: (inout AgentCallState) throws -> Value) throws -> Value {
        let package = storage(for: agentID).package
        guard FileManager.default.fileExists(atPath: package.path) else { throw WorkspaceError.missingAgent(agentID) }
        let descriptor = systemOpen(package.appendingPathComponent(".calls.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { systemClose(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        var state = try readCalls(agentID: agentID)
        let original = state
        let value = try change(&state)
        if state.pending != original.pending || state.placed != original.placed {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFile.write(encoder.encode(state), to: callsURL(agentID: agentID))
        }
        return value
    }
}
