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
    var modelIdentifier: String? = nil

    static func file(in workspace: URL, conversationID: UUID) -> URL {
        workspace.appendingPathComponent(".noodle/apple/conversations/\(conversationID.uuidString.lowercased()).json")
    }

    func save(in workspace: URL, conversationID: UUID) throws {
        let file = Self.file(in: workspace, conversationID: conversationID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(JSONEncoder().encode(self), to: file)
    }

    /// Original images stay in Noodle's attachment store. Keep a textual
    /// reference in the resumable transcript rather than serializing pixels or
    /// retaining process-local image objects in the completion receipt.
    static func persistable(_ transcript: Transcript) -> Transcript {
        #if canImport(FoundationModels, _version: 2)
        if #available(macOS 27, *) {
            return Transcript(entries: transcript.map { entry in
                guard case .prompt(var prompt) = entry else { return entry }
                prompt.segments = prompt.segments.map { segment in
                    guard case .attachment(let attachment) = segment else { return segment }
                    return .text(.init(id: attachment.id, content: "[Image attachment: \(attachment.label ?? "image"). The original message retains the image; these saved bytes contain no image data.]"))
                }
                return .prompt(prompt)
            })
        }
        #endif
        return transcript
    }

    /// macOS 26 fallback: keep complete turns, including their tool calls/results.
    /// Never restore the middle of a tool exchange. The runtime supplies fresh
    /// instructions and tool definitions.
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
