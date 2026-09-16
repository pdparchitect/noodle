import Foundation

/// UI state lives beside the workspace, keeping development and production separate.
/// Checkpoint each change so restoration does not depend on a clean application exit.
@MainActor final class ConversationWindowSession {
    private let fileURL: URL?
    private(set) var frames: [UUID: String]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let frames = try? JSONDecoder().decode([UUID: String].self, from: data) {
            self.frames = frames
        } else {
            frames = [:]
        }
    }

    func save(frame: String, for id: UUID) {
        var updated = frames
        updated[id] = frame
        persist(updated)
    }

    func remove(_ id: UUID) {
        var updated = frames
        updated.removeValue(forKey: id)
        persist(updated)
    }

    func retainConversations(_ ids: Set<UUID>) {
        persist(frames.filter { ids.contains($0.key) })
    }

    private func persist(_ updated: [UUID: String]) {
        guard updated != frames else { return }
        do {
            if let fileURL {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            }
            frames = updated
        } catch {
            NSLog("Could not save conversation windows: %@", error.localizedDescription)
        }
    }
}
