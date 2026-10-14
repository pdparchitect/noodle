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
}

public enum BotRequestStatus: String, Codable, Sendable {
    case waiting
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
