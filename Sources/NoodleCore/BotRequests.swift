import Darwin
import Foundation

public struct BotRequest: Codable, Hashable, Sendable {
    public let id: UUID
    public let askerID: UUID
    public let helperID: UUID
    /// Where the asker answers once the helper replies.
    public let conversationID: UUID
    public let text: String
    public var status: BotRequestStatus
    public let createdAt: Date
    public var answer: String?
    public var answeredAt: Date?
}

public enum BotRequestStatus: String, Codable, Sendable {
    case waiting, answered
}

public struct MessengerBot: Codable, Hashable, Sendable {
    public let bot: MessengerIdentity
    public let publicDescription: String?
}

struct BotRequestError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

/// Kept in the library, outside every workspace, because a request belongs to two bots and
/// neither may change it except through Messenger.
private struct BotRequestState: Codable {
    var requests: [BotRequest] = []
}

extension WorkspaceRepository {
    public func addBotRequest(askerID: UUID, helperID: UUID, conversationID: UUID, text: String,
                              now: Date = Date()) throws -> BotRequest {
        try updateBotRequests { state in
            // Whole seconds, as stored, so the request returned now equals the one read later.
            let request = BotRequest(id: UUID(), askerID: askerID, helperID: helperID, conversationID: conversationID,
                                     text: text, status: .waiting,
                                     createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))
            state.requests.append(request)
            return request
        }
    }

    /// A bot may ask only the bots it may list in that conversation; any other is reported missing, so
    /// asking never confirms that a bot it may not see exists.
    public func askBot(_ helperID: UUID, for agentID: UUID, in conversationID: UUID, text: String) throws -> BotRequest {
        guard try listBots(for: agentID, in: conversationID).contains(where: { $0.bot.agentID == helperID }) else {
            throw WorkspaceError.missingAgent(helperID)
        }
        return try addBotRequest(askerID: agentID, helperID: helperID, conversationID: conversationID, text: text)
    }

    public func listBotRequests(waitingFor agentID: UUID) throws -> [BotRequest] {
        try readBotRequests().requests.filter { $0.helperID == agentID && $0.status == .waiting }
    }

    /// Only the bot asked may answer, and only once.
    public func answerBotRequest(_ id: UUID, by agentID: UUID, answer: String, now: Date = Date()) throws -> BotRequest {
        try updateBotRequests { state in
            guard let index = state.requests.firstIndex(where: { $0.id == id && $0.helperID == agentID && $0.status == .waiting }) else {
                throw BotRequestError("No request \(id) is waiting for you. --list-requests shows the ones that are.")
            }
            state.requests[index].status = .answered
            state.requests[index].answer = answer
            state.requests[index].answeredAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            return state.requests[index]
        }
    }

    /// A Hub keeps bots for several people; a Mac's bots all have no owner, so they share one. In a
    /// conversation with a guest, only bots also shared with that guest are listed, so a shared bot
    /// never learns of its owner's private bots while it works for someone else.
    public func listBots(for agentID: UUID, in conversationID: UUID) throws -> [MessengerBot] {
        let agents = try loadAgents()
        guard let me = agents.first(where: { $0.id == agentID }) else { throw WorkspaceError.missingAgent(agentID) }
        let conversations = try loadConversations()
        guard let conversation = conversations.first(where: { $0.id == conversationID && $0.participantIDs.contains(agentID) }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let owner = try loadAgentOwner(me)?.id
        let sharedWithGuest = conversation.guest.map { guest in
            Set(conversations.filter { $0.guest?.id == guest.id }.flatMap(\.participantIDs))
        }
        return try agents.filter { agent in
            try agent.id != agentID && loadAgentOwner(agent)?.id == owner && sharedWithGuest?.contains(agent.id) != false
        }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { MessengerBot(bot: MessengerIdentity(handle: .bot, agentID: $0.id, displayName: $0.displayName),
                                publicDescription: $0.publicDescription) }
    }

    public func botRequests() throws -> [BotRequest] {
        try readBotRequests().requests
    }

    private var botRequestsURL: URL { rootURL.appendingPathComponent("bot-requests.json") }

    private func readBotRequests() throws -> BotRequestState {
        guard FileManager.default.fileExists(atPath: botRequestsURL.path) else { return BotRequestState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BotRequestState.self, from: Data(contentsOf: botRequestsURL))
    }

    /// Messenger and the runtime change the file from different threads, so changes take a lock.
    private func updateBotRequests<Value>(_ change: (inout BotRequestState) throws -> Value) throws -> Value {
        let descriptor = Darwin.open(rootURL.appendingPathComponent(".bot-requests.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        var state = try readBotRequests()
        let value = try change(&state)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(encoder.encode(state), to: botRequestsURL)
        return value
    }
}
