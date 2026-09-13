import Foundation

/// Noodle's session reference and durable, user-authorized context recovery.
/// The harness owns its session files; recovery never deletes or edits them.
public struct ACPSessionState: Codable, Equatable {
    public var sessionID: String?
    public var previousSessionIDs: [String]
    public var needsHistoryRecovery: Bool
    public var recoveryBlocked: Bool

    public init(sessionID: String? = nil) {
        self.sessionID = sessionID
        previousSessionIDs = []
        needsHistoryRecovery = false
        recoveryBlocked = false
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, previousSessionIDs, needsHistoryRecovery, recoveryBlocked
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        previousSessionIDs = try values.decodeIfPresent([String].self, forKey: .previousSessionIDs) ?? []
        needsHistoryRecovery = try values.decodeIfPresent(Bool.self, forKey: .needsHistoryRecovery) ?? false
        recoveryBlocked = try values.decodeIfPresent(Bool.self, forKey: .recoveryBlocked) ?? false
        guard sessionID.map(FxProtocol.validIdentifier) ?? needsHistoryRecovery,
              previousSessionIDs.allSatisfy(FxProtocol.validIdentifier) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ACP session state"))
        }
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Called only after confirmation and after the old runtime has stopped.
    /// Matching the exact session protects a reference changed while stopping.
    public static func prepareRecovery(at url: URL, replacing expectedSessionID: String) throws {
        var state = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard state.sessionID == expectedSessionID else {
            throw HarnessSetupError("The bot's session changed. Choose Kick again to check its current state.")
        }
        state.previousSessionIDs.append(expectedSessionID)
        state.sessionID = nil
        state.needsHistoryRecovery = true
        state.recoveryBlocked = false
        try state.save(to: url)
    }

    /// A click authorizes one more attempt, including when a previous attempt
    /// was interrupted by app shutdown. Retain the replacement if it was saved.
    public static func allowRecoveryRetry(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var state = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard state.needsHistoryRecovery, state.recoveryBlocked else { return }
        state.recoveryBlocked = false
        try state.save(to: url)
    }
}
