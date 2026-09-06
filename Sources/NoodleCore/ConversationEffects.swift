import Darwin
import Foundation

/// Extend this catalogue and the UI renderer together. Effects never execute code.
public enum ConversationEffectKind: String, Codable, CaseIterable, Sendable {
    case confetti

    static let messengerInstructions = """
    You can celebrate a meaningful result with a temporary chat effect: `./.agents/skills/messenger/messenger --effect confetti --conversation <uuid>`. Use `--list-effects` to discover supported effect names. Effects are optional, should be used sparingly, and never replace a reply. They play once only when the user has that conversation in the foreground, expire after 30 seconds, and respect Reduce Motion. The JSON receipt confirms queuing, not that the user saw it. Effects do not create messages or notify agents. For a retry, reuse an optional `--request-id <uuid>`; recent IDs are retained for up to five minutes (32 events). You can only target conversations you participate in.
    """
}

public struct ConversationEffect: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let agentID: UUID
    /// A string lets older clients skip future effect kinds without breaking the queue.
    public let kind: String
    public let createdAt: Date
    public let expiresAt: Date
    public var consumedAt: Date?

    public var supportedKind: ConversationEffectKind? { ConversationEffectKind(rawValue: kind) }
}

public enum ConversationEffectError: LocalizedError, Equatable {
    case notParticipant, unsupportedKind, rateLimited, requestConflict, invalidStore

    public var errorDescription: String? {
        switch self {
        case .notParticipant: return "You can only send effects to conversations you participate in."
        case .unsupportedKind: return "Unsupported effect. Use --list-effects to see supported effects."
        case .rateLimited: return "An effect was just sent to this conversation. Wait two seconds before sending another."
        case .requestConflict: return "This request ID has already been used for another effect."
        case .invalidStore: return "The conversation effect queue could not be read safely."
        }
    }
}

extension WorkspaceRepository {
    /// Effects do not create messages, wake bots, mark chats unread, or reorder them.
    public func sendEffect(
        agentID: UUID, conversationID: UUID, kind: String,
        requestID: UUID = UUID(), now: Date = Date()
    ) throws -> ConversationEffect {
        guard ConversationEffectKind(rawValue: kind) != nil else { throw ConversationEffectError.unsupportedKind }
        return try withEffectsLock(conversationID) {
            let conversation = try effectConversation(conversationID)
            guard conversation.participantIDs.contains(agentID),
                  try loadAgents().contains(where: { $0.id == agentID }) else {
                throw ConversationEffectError.notParticipant
            }
            var queue = try readEffects(conversationID)
            if let existing = queue.events.first(where: { $0.id == requestID }) {
                guard existing.agentID == agentID, existing.kind == kind else {
                    throw ConversationEffectError.requestConflict
                }
                return existing
            }
            if let latest = queue.events.map(\.createdAt).max(), now.timeIntervalSince(latest) < 2 {
                throw ConversationEffectError.rateLimited
            }
            let event = ConversationEffect(id: requestID, conversationID: conversationID,
                agentID: agentID, kind: kind, createdAt: now,
                expiresAt: now.addingTimeInterval(30), consumedAt: nil)
            queue.events = Array(queue.events.filter { now.timeIntervalSince($0.createdAt) < 300 }.suffix(31))
            queue.events.append(event)
            try writeEffects(queue, conversationID)
            return event
        }
    }

    /// Atomically claims the newest live effect. Reopening a view cannot replay it.
    /// Call only for the visible foreground chat; a CLI receipt means queued, not displayed.
    public func takePendingEffect(conversationID: UUID, now: Date = Date()) throws -> ConversationEffect? {
        let file = conversationDirectory(id: conversationID).appendingPathComponent("effects.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try withEffectsLock(conversationID) {
            let conversation = try effectConversation(conversationID)
            var queue = try readEffects(conversationID)
            let live = queue.events.filter {
                $0.consumedAt == nil && $0.conversationID == conversationID &&
                $0.createdAt <= now && $0.expiresAt > now &&
                $0.expiresAt.timeIntervalSince($0.createdAt) <= 30 &&
                $0.supportedKind != nil && conversation.participantIDs.contains($0.agentID)
            }.max { $0.createdAt < $1.createdAt }
            var changed = false
            for index in queue.events.indices where queue.events[index].consumedAt == nil {
                queue.events[index].consumedAt = now
                changed = true
            }
            if changed { try writeEffects(queue, conversationID) }
            return live
        }
    }

    private func effectConversation(_ id: UUID) throws -> BotConversation {
        guard let conversation = try loadConversations().first(where: { $0.id == id }) else {
            throw WorkspaceError.missingConversation(id)
        }
        return conversation
    }

    private func withEffectsLock<Value>(_ id: UUID, operation: () throws -> Value) throws -> Value {
        _ = try effectConversation(id)
        let file = conversationDirectory(id: id).appendingPathComponent(".effects.lock")
        let descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func readEffects(_ id: UUID) throws -> EffectQueue {
        let file = conversationDirectory(id: id).appendingPathComponent("effects.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return EffectQueue() }
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 65_536 else {
            throw ConversationEffectError.invalidStore
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let queue = try decoder.decode(EffectQueue.self, from: Data(contentsOf: file))
        guard queue.version == 1, queue.events.count <= 32 else { throw ConversationEffectError.invalidStore }
        return queue
    }

    private func writeEffects(_ queue: EffectQueue, _ id: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(queue).write(
            to: conversationDirectory(id: id).appendingPathComponent("effects.json"), options: .atomic)
    }
}

private struct EffectQueue: Codable {
    var version = 1
    var events: [ConversationEffect] = []
}
