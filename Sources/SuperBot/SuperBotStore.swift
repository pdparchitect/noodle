import AppKit
import Foundation
import Observation
import SuperBotCore

@MainActor
@Observable
final class SuperBotStore {
    enum CreationSheet: Identifiable {
        case bot
        case group

        var id: String {
            switch self {
            case .bot: return "bot"
            case .group: return "group"
            }
        }
    }

    private(set) var agents: [AgentRecord] = []
    private(set) var conversations: [BotConversation] = []
    private(set) var messagesByConversation: [UUID: [ChatMessage]] = [:]
    var selectedConversationID: UUID?
    var searchText = ""
    var draft = ""
    var creationSheet: CreationSheet?
    var agentBeingRenamed: AgentRecord?
    var errorMessage: String?

    let repository: WorkspaceRepository

    init(repository: WorkspaceRepository? = nil) {
        if let repository {
            self.repository = repository
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.repository = WorkspaceRepository(
                rootURL: applicationSupport.appendingPathComponent("SuperBot", isDirectory: true),
                launcherExecutableURL: Bundle.main.executableURL
            )
        }

        reload()
    }

    var selectedConversation: BotConversation? {
        conversations.first(where: { $0.id == selectedConversationID })
    }

    var filteredConversations: [BotConversation] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return conversations }

        return conversations.filter { conversation in
            title(for: conversation).localizedCaseInsensitiveContains(term) ||
                participants(for: conversation).contains {
                    $0.displayName.localizedCaseInsensitiveContains(term)
                } ||
                messages(for: conversation).contains {
                    $0.body.localizedCaseInsensitiveContains(term)
                }
        }
    }

    var directConversations: [BotConversation] {
        filteredConversations.filter { $0.kind == .direct }
    }

    var groupConversations: [BotConversation] {
        filteredConversations.filter { $0.kind == .group }
    }

    func reload() {
        do {
            try repository.prepare()
            agents = try repository.loadAgents()
            try repository.synchronizeAgentWorkspaces(agents)
            conversations = try repository.loadConversations()
            messagesByConversation = try Dictionary(
                uniqueKeysWithValues: conversations.map {
                    ($0.id, try repository.loadMessages(conversationID: $0.id))
                }
            )

            if let selectedConversationID,
               conversations.contains(where: { $0.id == selectedConversationID }) {
                return
            }
            selectedConversationID = conversations.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAgent(named name: String) -> Bool {
        do {
            let created = try repository.createAgent(named: name)
            agents.append(created.agent)
            conversations.insert(created.conversation, at: 0)
            messagesByConversation[created.conversation.id] = []
            selectedConversationID = created.conversation.id
            creationSheet = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func renameAgent(_ agent: AgentRecord, to name: String) -> Bool {
        do {
            let renamed = try repository.renameAgent(agent, to: name)
            if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                agents[index] = renamed
            }

            for index in conversations.indices where
                conversations[index].kind == .direct &&
                conversations[index].participantIDs == [agent.id] {
                conversations[index].displayName = renamed.displayName
                conversations[index].updatedAt = renamed.updatedAt
                try repository.updateConversation(conversations[index])
            }

            agentBeingRenamed = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func createGroup(named name: String, participantIDs: Set<UUID>) -> Bool {
        do {
            let conversation = try repository.createGroup(
                named: name,
                participantIDs: Array(participantIDs),
                existingAgents: agents
            )
            conversations.insert(conversation, at: 0)
            messagesByConversation[conversation.id] = []
            selectedConversationID = conversation.id
            creationSheet = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func sendDraft() {
        guard let conversation = selectedConversation else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        let message = ChatMessage(
            conversationID: conversation.id,
            author: .user,
            body: body,
            delivery: .queued
        )

        do {
            try repository.append(message)
            messagesByConversation[conversation.id, default: []].append(message)

            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index].updatedAt = message.createdAt
                try repository.updateConversation(conversations[index])
                conversations.sort { $0.updatedAt > $1.updatedAt }
            }

            draft = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func messages(for conversation: BotConversation) -> [ChatMessage] {
        messagesByConversation[conversation.id, default: []]
    }

    func participants(for conversation: BotConversation) -> [AgentRecord] {
        conversation.participantIDs.compactMap { id in
            agents.first(where: { $0.id == id })
        }
    }

    func title(for conversation: BotConversation) -> String {
        if conversation.kind == .direct,
           let agent = participants(for: conversation).first {
            return agent.displayName
        }
        return conversation.displayName
    }

    func preview(for conversation: BotConversation) -> String {
        messages(for: conversation).last?.body ?? "No messages yet"
    }

    func revealWorkspace(for agent: AgentRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([repository.directory(for: agent)])
    }
}
