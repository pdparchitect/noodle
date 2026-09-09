import Foundation

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
