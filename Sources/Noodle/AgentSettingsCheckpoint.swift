import Foundation
import NoodleCore

/// Restore only settings owned by the app. Open directory descriptors keep
/// rollback inside the original directories even if a workspace path changes.
/// Transcripts, runtime state, and the bot's working files are never copied.
@MainActor final class AgentSettingsCheckpoint {
    private struct Entry {
        let directory: WorkspaceMailbox
        let name: String
        let data: Data?
    }
    private var entries: [Entry] = []

    init(repository: WorkspaceRepository, agent: AgentRecord? = nil, conversations: [BotConversation] = []) throws {
        try capture(WorkspaceMailbox(workspace: repository.rootURL, path: ""), names: ["computers.json"])
        try capture(WorkspaceMailbox(workspace: repository.rootURL, path: "MCP", create: true), names: ["connections.json"])
        if let agent {
            let layout = repository.storage(for: agent.id)
            try capture(WorkspaceMailbox(workspace: layout.package, path: ""), names: ["agent.json"])
            for conversation in conversations where conversation.kind == .direct && conversation.participantIDs == [agent.id] {
                try capture(WorkspaceMailbox(workspace: repository.conversationDirectory(id: conversation.id), path: ""), names: ["conversation.json"])
            }
        }
    }

    private func capture(_ directory: WorkspaceMailbox, names: [String]) throws {
        for name in names {
            entries.append(Entry(directory: directory, name: name,
                data: directory.contains(name) ? try directory.read(name, limit: 32 * 1_048_576) : nil))
        }
    }

    func restore() throws {
        var firstError: Error?
        for entry in entries.reversed() {
            do {
                if let data = entry.data {
                    if (try? entry.directory.read(entry.name, limit: 32 * 1_048_576)) != data {
                        try entry.directory.writeData(data, named: entry.name)
                    }
                } else if entry.directory.contains(entry.name) {
                    entry.directory.remove(entry.name)
                    guard !entry.directory.contains(entry.name) else { throw CocoaError(.fileWriteUnknown) }
                }
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
}
