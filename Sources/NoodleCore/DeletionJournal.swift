import Foundation

/// Deletions that must not be lost when they fail, such as a removed account's saved secret.
/// Each is written down before it is tried and stays until it succeeds, so the next `run`,
/// even after a restart, tries it again. Deleting something already gone must count as success.
@MainActor public final class DeletionJournal<ID: Codable & Hashable & Sendable> {
    private let url: URL
    public private(set) var scheduled: [ID]
    private var running: Set<ID> = []

    public init(url: URL) {
        self.url = url
        scheduled = (try? JSONDecoder().decode([ID].self, from: Data(contentsOf: url))) ?? []
    }

    /// Throws when the deletions could not be written down, so the caller keeps what it would delete.
    public func schedule(_ ids: some Sequence<ID>) throws {
        var next = scheduled
        for id in ids where !next.contains(id) { next.append(id) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(JSONEncoder().encode(next), to: url)
        scheduled = next
    }

    /// Tries every scheduled deletion not already under way, and returns the first failure.
    @discardableResult public func run(_ delete: (ID) async throws -> Void) async -> Error? {
        var failure: Error?
        for id in scheduled where running.insert(id).inserted {
            defer { running.remove(id) }
            do {
                try await delete(id)
                scheduled.removeAll { $0 == id }
                // If this write fails the entry is only retried, which is harmless.
                try? AtomicFile.write(JSONEncoder().encode(scheduled), to: url)
            } catch { failure = failure ?? error }
        }
        return failure
    }
}
