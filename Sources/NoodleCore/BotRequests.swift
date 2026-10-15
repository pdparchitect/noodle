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
    /// When the asking bot read the answer; each answer is handed over once.
    public var answerReadAt: Date?
}

/// A request as the asking conversation shows it, updated as the request changes. It is never
/// delivered to bots. The answer appears only once the asking bot has collected it, so an answer
/// withheld from the conversation never shows there.
public struct BotRequestLine: Codable, Hashable, Sendable {
    public let requestID: UUID
    /// Nil, like the text, on a Hub's copy of a line from a bot on its owner's Mac, which keeps them.
    public let helperID: UUID?
    public let helperName: String
    public let text: String?
    public var status: BotRequestStatus
    public var answer: String?

    public init(requestID: UUID, helperID: UUID?, helperName: String, text: String?, status: BotRequestStatus, answer: String? = nil) {
        self.requestID = requestID; self.helperID = helperID; self.helperName = helperName
        self.text = text; self.status = status; self.answer = answer
    }
}

public enum BotRequestStatus: String, Codable, Sendable {
    case waiting, answered, cancelled, expired, withheld
}

/// Limits that keep bots asking each other from turning into a loop.
public enum BotRequestLimits {
    public static let waiting = 3
    public static let depth = 2
    /// A request still waiting this long expires, and the bot that asked is told.
    public static let expiry: TimeInterval = 24 * 3_600
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

    mutating func expire(at now: Date) {
        for index in requests.indices where requests[index].status == .waiting
            && requests[index].createdAt.addingTimeInterval(BotRequestLimits.expiry) <= now {
            requests[index].status = .expired
        }
    }

    /// The bots up the chain of requests waiting for this bot, with how many steps up the chain goes.
    /// A request is asked to answer another while one is waiting for its asker.
    func chain(above agentID: UUID, visited: Set<UUID> = []) -> (bots: Set<UUID>, depth: Int) {
        var bots: Set<UUID> = [], depth = 0
        for request in requests where request.helperID == agentID && request.status == .waiting
            && !visited.contains(request.askerID) {
            let above = chain(above: request.askerID, visited: visited.union([agentID]))
            bots.formUnion(above.bots.union([request.askerID]))
            depth = max(depth, above.depth + 1)
        }
        return (bots, depth)
    }
}

extension WorkspaceRepository {
    public func addBotRequest(askerID: UUID, helperID: UUID, conversationID: UUID, text: String,
                              now: Date = Date()) throws -> BotRequest {
        try addBotRequest(askerID: askerID, helperID: helperID, conversationID: conversationID, text: text, now: now) { _ in }
    }

    private func addBotRequest(askerID: UUID, helperID: UUID, conversationID: UUID, text: String, now: Date,
                               check: (BotRequestState) throws -> Void) throws -> BotRequest {
        try updateBotRequests(now: now) { state in
            try check(state)
            // Whole seconds, as stored, so the request returned now equals the one read later.
            let request = BotRequest(id: UUID(), askerID: askerID, helperID: helperID, conversationID: conversationID,
                                     text: text, status: .waiting,
                                     createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))
            state.requests.append(request)
            return request
        }
    }

    /// A bot may ask only the bots it may list in that conversation; any other is reported missing, so
    /// asking never confirms that a bot it may not see exists. The limits stop bots asking each other
    /// in a loop: a chain never reaches back to a bot already in it or goes deeper than its limit, and
    /// turns woken by requests and answers count towards waking in a row.
    public func askBot(_ helperID: UUID, for agentID: UUID, in conversationID: UUID, text: String,
                       now: Date = Date()) throws -> BotRequest {
        guard let helper = try listBots(for: agentID, in: conversationID).first(where: { $0.bot.agentID == helperID }) else {
            throw WorkspaceError.missingAgent(helperID)
        }
        guard try wakesInARow(agentID: agentID) < AgentWakeLimits.withoutOutsideMessages else {
            throw BotRequestError("You have been woken \(AgentWakeLimits.withoutOutsideMessages) times with no message from anyone else. Wait for a message before asking another bot.")
        }
        let request = try addBotRequest(askerID: agentID, helperID: helperID, conversationID: conversationID,
                                        text: text, now: now) { state in
            guard state.requests.filter({ $0.askerID == agentID && $0.status == .waiting }).count < BotRequestLimits.waiting else {
                throw BotRequestError("You already have \(BotRequestLimits.waiting) requests waiting for answers. Wait for one, or carry on with what you have.")
            }
            let chain = state.chain(above: agentID)
            guard !chain.bots.contains(helperID) else {
                throw BotRequestError("That bot is waiting for your answer, directly or further up the chain, so asking it would go round in a loop. Answer with what you have.")
            }
            guard chain.depth < BotRequestLimits.depth else {
                throw BotRequestError("You are answering a chain of requests already \(BotRequestLimits.depth) deep, the most allowed. Answer with what you have.")
            }
        }
        try wakeFromAnotherBot(agentID: helperID, note: AgentWake.requestNote, now: request.createdAt)
        try wakeForExpiry(agentID: agentID, requestID: request.id, at: request.createdAt.addingTimeInterval(BotRequestLimits.expiry))
        var line = ChatMessage(conversationID: conversationID, author: .agent(agentID), body: "Asked \(helper.bot.displayName)",
                               createdAt: request.createdAt, delivery: .delivered)
        line.request = BotRequestLine(requestID: request.id, helperID: helperID, helperName: helper.bot.displayName,
                                      text: text, status: .waiting)
        try append(line)
        return request
    }

    public func listBotRequests(waitingFor agentID: UUID, now: Date = Date()) throws -> [BotRequest] {
        var state = try readBotRequests()
        state.expire(at: now)
        return state.requests.filter { $0.helperID == agentID && $0.status == .waiting }
    }

    /// Only the bot asked may answer, and only once.
    public func answerBotRequest(_ id: UUID, by agentID: UUID, answer: String, now: Date = Date()) throws -> BotRequest {
        let answered = try updateBotRequests(now: now) { state in
            guard let index = state.requests.firstIndex(where: { $0.id == id && $0.helperID == agentID }) else {
                throw BotRequestError("No request \(id) is waiting for you. --list-requests shows the ones that are.")
            }
            switch state.requests[index].status {
            case .waiting: break
            case .answered, .withheld: throw BotRequestError("You have already answered request \(id).")
            case .cancelled: throw BotRequestError("Request \(id) was cancelled by the bot that asked, so it needs no answer.")
            case .expired: throw BotRequestError("Request \(id) expired before it was answered, so it needs no answer.")
            }
            state.requests[index].status = .answered
            state.requests[index].answer = answer
            state.requests[index].answeredAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            return state.requests[index]
        }
        try removeExpiryWake(agentID: answered.askerID, requestID: id)
        // The answer shows only once the asking bot collects it, after sharing is checked again.
        try? updateRequestLine(requestID: id, conversationID: answered.conversationID) { $0.status = .answered }
        try wakeFromAnotherBot(agentID: answered.askerID, note: AgentWake.answerNote, now: now)
        return answered
    }

    /// Only the bot that asked may cancel, and only while the request is waiting.
    public func cancelBotRequest(_ id: UUID, by agentID: UUID, now: Date = Date()) throws -> BotRequest {
        let cancelled = try updateBotRequests(now: now) { state in
            guard let index = state.requests.firstIndex(where: { $0.id == id && $0.askerID == agentID && $0.status == .waiting }) else {
                throw BotRequestError("No request \(id) of yours is waiting for an answer.")
            }
            state.requests[index].status = .cancelled
            return state.requests[index]
        }
        try removeExpiryWake(agentID: agentID, requestID: id)
        try? updateRequestLine(requestID: id, conversationID: cancelled.conversationID) { $0.status = .cancelled }
        return cancelled
    }

    /// Hands over the answers to the bot's requests that it has not read yet, oldest answer first.
    /// Hands over expired requests too, with no answer, so the bot can tell the person. Sharing may
    /// have changed since the bot asked, so an answer from a bot it may no longer ask in that
    /// conversation is withheld and dropped.
    public func listBotAnswers(for agentID: UUID, now: Date = Date()) throws -> [BotRequest] {
        let conversations = Set(try readBotRequests().requests.filter { $0.askerID == agentID }.map(\.conversationID))
        var askable: [UUID: Set<UUID>] = [:]
        for conversation in conversations {
            askable[conversation] = Set(((try? listBots(for: agentID, in: conversation)) ?? []).compactMap(\.bot.agentID))
        }
        let answers = try updateBotRequests(now: now) { state in
            let read = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            var answers: [BotRequest] = []
            for index in state.requests.indices where state.requests[index].askerID == agentID
                && [.answered, .expired].contains(state.requests[index].status) && state.requests[index].answerReadAt == nil {
                let request = state.requests[index]
                if request.status == .answered, askable[request.conversationID]?.contains(request.helperID) != true {
                    state.requests[index].status = .withheld
                    state.requests[index].answer = nil
                }
                state.requests[index].answerReadAt = read
                answers.append(state.requests[index])
            }
            return answers.sorted { ($0.answeredAt ?? $0.createdAt) < ($1.answeredAt ?? $1.createdAt) }
        }
        for request in answers {
            try? updateRequestLine(requestID: request.id, conversationID: request.conversationID) {
                $0.status = request.status
                $0.answer = request.answer
            }
        }
        return answers
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
    /// Requests past their expiry are marked expired before any change.
    private func updateBotRequests<Value>(now: Date = Date(), _ change: (inout BotRequestState) throws -> Value) throws -> Value {
        let descriptor = Darwin.open(rootURL.appendingPathComponent(".bot-requests.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        var state = try readBotRequests()
        state.expire(at: now)
        let value = try change(&state)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(encoder.encode(state), to: botRequestsURL)
        return value
    }
}
