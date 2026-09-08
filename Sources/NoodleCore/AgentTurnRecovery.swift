import Foundation

/// Durable wake intent, scoped to the same provider/access mode as its session.
/// Stopping or losing a process must not clear this marker. Only a terminal
/// turn result does; the agent decides how to safely resume unfinished work.
public struct AgentTurnRecovery {
    private let url: URL
    private var token: Data?

    public init(sessionStateURL: URL) {
        url = sessionStateURL.appendingPathExtension("unfinished")
    }

    public var hasUnfinishedTurn: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public mutating func begin() throws {
        let next = Data(UUID().uuidString.utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try next.write(to: url, options: .atomic)
        token = next
    }

    public mutating func finish() throws {
        guard let token else { return }
        // A late callback from an older runtime cannot erase a newer turn.
        do {
            if try Data(contentsOf: url) == token {
                try FileManager.default.removeItem(at: url)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // Already cleared, e.g. by an explicit session reset.
        }
        self.token = nil
    }
}
