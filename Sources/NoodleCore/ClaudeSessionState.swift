import Foundation

/// The app's resume pointer, not Claude's transcript or the bot's workspace.
public struct ClaudeSessionState {
    private struct Persisted: Codable {
        let version: Int
        let sessionID: UUID
    }

    public let sessionID: UUID
    public private(set) var shouldResume: Bool
    private let url: URL
    private var initialized = false

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(Persisted.self, from: data), state.version == 1 {
            sessionID = state.sessionID
            shouldResume = true
        } else {
            sessionID = UUID()
            shouldResume = false
        }
    }

    /// Only persist after Claude acknowledges the actual session, never before launch.
    public mutating func confirm(sessionID confirmedID: UUID) throws {
        guard confirmedID == sessionID else { throw CocoaError(.coderInvalidValue) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Persisted(version: 1, sessionID: sessionID)).write(to: url, options: .atomic)
        initialized = true
        shouldResume = true
    }

    /// Do not confuse authentication, quota, model, or transport failures with a missing session.
    public mutating func invalidateMissingSession(from message: [String: Any]) throws -> Bool {
        guard shouldResume, !initialized,
              message["type"] as? String == "result",
              message["subtype"] as? String == "error_during_execution",
              message["is_error"] as? Bool == true,
              message["num_turns"] as? Int == 0,
              let rawID = message["session_id"] as? String,
              UUID(uuidString: rawID) == sessionID else { return false }
        let expected = "No conversation found with session ID: \(sessionID.uuidString)".lowercased()
        let errors = (message["errors"] as? [String] ?? []) + [message["result"] as? String ?? ""]
        guard errors.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected
        }) else { return false }

        // Never remove another runtime's newer pointer. No transcript is deleted.
        if let data = try? Data(contentsOf: url),
           let current = try? JSONDecoder().decode(Persisted.self, from: data),
           current.sessionID == sessionID {
            try FileManager.default.removeItem(at: url)
        }
        shouldResume = false
        return true
    }
}
