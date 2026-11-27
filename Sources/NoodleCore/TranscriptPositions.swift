import Foundation

/// Which messages a transcript holds, in every app: the newest page, or from where the reader last was, and a page
/// more each time the top is reached. Layout work for every update grows with the rows a transcript holds, not with
/// what is on screen. Later replies add to what shows rather than pushing the oldest rows out from under the reader.
public enum TranscriptPaging {
    /// Messages shown when a conversation opens, and added each time the top is reached.
    public static let pageSize = 100

    /// The index of the oldest message shown: from `firstShownID` once set, else the newest page and the reading position.
    public static func firstShown(in messages: [ChatMessage], firstShownID: UUID?, reading: UUID?) -> Int {
        if let firstShownID, let index = messages.firstIndex(where: { $0.id == firstShownID }) { return index }
        let reading = reading.flatMap { id in messages.firstIndex { $0.id == id } }
        return min(max(messages.count - pageSize, 0), reading ?? .max)
    }

    /// The message to show from once the top is reached.
    public static func pageBefore(_ first: Int, in messages: [ChatMessage]) -> UUID { messages[max(first - pageSize, 0)].id }
}

/// Reading state only: no message contents, attachment paths or agent data.
public struct TranscriptViewport: Codable, Equatable, Sendable {
    public var offset: CGFloat
    public var isAtBottom: Bool
    public var messageID: UUID?

    public init(offset: CGFloat = 0, isAtBottom: Bool = true, messageID: UUID? = nil) {
        self.offset = offset
        self.isAtBottom = isAtBottom
        self.messageID = messageID
    }

    public func restored(availableMessageIDs: Set<UUID>) -> Self {
        guard offset.isFinite, offset >= 0 else { return Self() }
        if isAtBottom { return Self() }
        // Never restore a now-removed message using an obsolete pixel offset.
        if let messageID, !availableMessageIDs.contains(messageID) { return Self() }
        return self
    }

    /// Where a transcript opens to show a message, in every app: at the message, or the bottom for the latest one,
    /// which keeps following new replies. Nil when the conversation does not hold it.
    public static func revealing(_ messageID: UUID, in messages: [ChatMessage]) -> Self? {
        guard messages.contains(where: { $0.id == messageID }) else { return nil }
        return messages.last?.id == messageID ? Self() : Self(isAtBottom: false, messageID: messageID)
    }
}

extension Notification.Name {
    /// Asks the transcript showing a message to scroll to it, as after a click on its notification.
    public static let revealTranscriptMessage = Notification.Name("revealTranscriptMessage")
}

/// Kept with the repository so development/test and production workspaces stay
/// separate. Writes happen at scroll checkpoints, not on every geometry update.
public final class TranscriptPositionStore {
    private let fileURL: URL
    private var positions: [UUID: TranscriptViewport]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([UUID: TranscriptViewport].self, from: data) {
            positions = decoded.filter { $0.value.offset.isFinite && $0.value.offset >= 0 }
        } else {
            positions = [:]
        }
    }

    public func viewport(for conversationID: UUID) -> TranscriptViewport {
        positions[conversationID] ?? TranscriptViewport()
    }

    public func save(_ viewport: TranscriptViewport, for conversationID: UUID) throws {
        guard viewport.offset.isFinite, viewport.offset >= 0 else { return }
        var updated = positions
        updated[conversationID] = viewport
        try persist(updated)
    }

    public func retainConversations(_ ids: Set<UUID>) throws {
        try persist(positions.filter { ids.contains($0.key) })
    }

    private func persist(_ updated: [UUID: TranscriptViewport]) throws {
        guard updated != positions else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
        positions = updated
    }
}
