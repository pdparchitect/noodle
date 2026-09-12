import Foundation
import FoundationModels
import NoodleCore

/// Only actual Foundation Models turns are resumed. Visible chat can include
/// other harnesses, grouped deliveries and failed replies; it is a source for
/// history retrieval, not a native model transcript.
@available(macOS 26, *)
struct AppleConversationSession: Codable {
    let transcript: Transcript
    let messageIDs: Set<UUID>
    let reply: String

    static func file(in workspace: URL, conversationID: UUID) -> URL {
        workspace.appendingPathComponent(".noodle/apple/conversations/\(conversationID.uuidString.lowercased()).json")
    }

    func save(in workspace: URL, conversationID: UUID) throws {
        let file = Self.file(in: workspace, conversationID: conversationID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(JSONEncoder().encode(self), to: file)
    }

    /// Keep complete turns, including their tool calls/results. Never start a
    /// restored transcript in the middle of a tool exchange. Instructions and
    /// tool definitions are supplied afresh by the runtime.
    func recentEntries(reservingPromptBytes: Int = 0) -> [Transcript.Entry] {
        let budget = max(0, 6_000 - reservingPromptBytes)
        var turns: [[Transcript.Entry]] = []
        for entry in transcript {
            switch entry {
            case .instructions: continue
            case .prompt: turns.append([entry])
            default:
                if !turns.isEmpty { turns[turns.count - 1].append(entry) }
            }
        }
        var kept: [[Transcript.Entry]] = []
        var bytes = 0
        for turn in turns.suffix(8).reversed() {
            let count = turn.reduce(0) { $0 + $1.description.utf8.count }
            guard bytes + count <= budget else { break }
            bytes += count
            kept.append(turn)
        }
        return kept.reversed().flatMap { $0 }
    }
}
