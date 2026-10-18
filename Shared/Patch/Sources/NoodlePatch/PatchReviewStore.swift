import Foundation

/// The files of each patch attachment the person has ticked off as viewed. Only theirs, on this
/// device, and never sent to a bot.
public final class PatchReviewStore {
    private let fileURL: URL
    /// Paths, by attachment, by conversation.
    private var viewed: [UUID: [UUID: Set<String>]]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([UUID: [UUID: Set<String>]].self, from: data) {
            viewed = decoded
        } else {
            viewed = [:]
        }
    }

    public func viewed(attachment: UUID, in conversation: UUID) -> Set<String> {
        viewed[conversation]?[attachment] ?? []
    }

    public func save(_ paths: Set<String>, attachment: UUID, in conversation: UUID) throws {
        var updated = viewed
        updated[conversation, default: [:]][attachment] = paths.isEmpty ? nil : paths
        if updated[conversation]?.isEmpty == true { updated[conversation] = nil }
        try persist(updated)
    }

    public func retainConversations(_ ids: Set<UUID>) throws {
        try persist(viewed.filter { ids.contains($0.key) })
    }

    private func persist(_ updated: [UUID: [UUID: Set<String>]]) throws {
        guard updated != viewed else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
        viewed = updated
    }
}
