import Foundation

/// The app's resume pointer. The CLI names its own conversations and silently
/// starts a new one when asked for one it no longer has, so its answer is kept.
public struct AntigravitySessionState {
    private struct Persisted: Codable {
        let version: Int
        let conversationID: UUID
    }

    public private(set) var conversationID: UUID?
    private let url: URL

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(Persisted.self, from: data), state.version == 1 {
            conversationID = state.conversationID
        }
    }

    public mutating func confirm(conversationID confirmedID: UUID) throws {
        guard confirmedID != conversationID else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Persisted(version: 1, conversationID: confirmedID)).write(to: url, options: .atomic)
        conversationID = confirmedID
    }
}
