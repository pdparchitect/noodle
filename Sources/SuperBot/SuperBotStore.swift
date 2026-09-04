import AppKit
import Foundation
import Observation
import SuperBotCore
import UniformTypeIdentifiers

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
    private(set) var attachmentsByConversation: [UUID: [ConversationAttachment]] = [:]
    var selectedConversationID: UUID?
    var searchText = ""
    var draft = ""
    var creationSheet: CreationSheet?
    var agentBeingEdited: AgentRecord?
    var groupBeingEdited: BotConversation?
    var errorMessage: String?
    var pendingAttachments: [ConversationAttachment] = []

    let repository: WorkspaceRepository
    let runtime = AgentRuntimeCoordinator()

    init(repository: WorkspaceRepository? = nil) {
        if let repository {
            self.repository = repository
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let bundledMessenger = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/messenger")
            self.repository = WorkspaceRepository(
                rootURL: applicationSupport.appendingPathComponent("SuperBot", isDirectory: true),
                launcherExecutableURL: FileManager.default.isExecutableFile(atPath: bundledMessenger.path)
                    ? bundledMessenger
                    : Bundle.main.executableURL
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
            attachmentsByConversation = try Dictionary(
                uniqueKeysWithValues: conversations.map {
                    ($0.id, try repository.loadAttachments(conversationID: $0.id))
                }
            )
            runtime.refresh(agents: agents)

            if let selectedConversationID,
               conversations.contains(where: { $0.id == selectedConversationID }) {
                return
            }
            selectedConversationID = conversations.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAgent(
        named name: String,
        harnessIdentifier: String,
        modelIdentifier: String?,
        reasoningEffort: String?
    ) -> Bool {
        do {
            let created = try repository.createAgent(
                named: name,
                harnessIdentifier: harnessIdentifier,
                modelIdentifier: modelIdentifier,
                reasoningEffort: reasoningEffort
            )
            agents.append(created.agent)
            conversations.insert(created.conversation, at: 0)
            messagesByConversation[created.conversation.id] = []
            attachmentsByConversation[created.conversation.id] = []
            runtime.refresh(agents: agents)
            runtime.start(agent: created.agent, repository: repository)
            selectedConversationID = created.conversation.id
            creationSheet = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateAgent(
        _ agent: AgentRecord,
        name: String,
        harnessIdentifier: String,
        modelIdentifier: String?,
        reasoningEffort: String?
    ) -> Bool {
        do {
            let updated = try repository.updateAgent(
                agent,
                displayName: name,
                harnessIdentifier: harnessIdentifier,
                modelIdentifier: modelIdentifier,
                reasoningEffort: reasoningEffort
            )
            if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                agents[index] = updated
            }

            for index in conversations.indices where
                conversations[index].kind == .direct &&
                conversations[index].participantIDs == [agent.id] {
                conversations[index].displayName = updated.displayName
                conversations[index].updatedAt = updated.updatedAt
                try repository.updateConversation(conversations[index])
            }

            try repository.synchronizeAgentWorkspace(updated)
            runtime.restart(agent: updated, repository: repository)
            agentBeingEdited = nil
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
            attachmentsByConversation[conversation.id] = []
            selectedConversationID = conversation.id
            creationSheet = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateGroup(_ conversation: BotConversation, participantIDs: Set<UUID>) -> Bool {
        do {
            let updated = try repository.updateGroupParticipants(
                conversationID: conversation.id,
                participantIDs: Array(participantIDs),
                existingAgents: agents
            )
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index] = updated
                conversations.sort { $0.updatedAt > $1.updatedAt }
            }
            groupBeingEdited = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func delete(_ conversation: BotConversation) -> Bool {
        let agent = conversation.kind == .direct
            ? participants(for: conversation).first
            : nil

        if let agent {
            runtime.stop(agentID: agent.id)
        }

        do {
            if let agent {
                try repository.deleteAgent(agent)
            } else {
                try repository.deleteConversation(id: conversation.id)
            }

            if selectedConversationID == conversation.id {
                selectedConversationID = nil
                draft = ""
                pendingAttachments = []
            }
            reload()
            agentBeingEdited = nil
            groupBeingEdited = nil
            return true
        } catch {
            if let agent {
                runtime.start(agent: agent, repository: repository)
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deletionMessage(for conversation: BotConversation) -> String {
        let name = title(for: conversation)
        if conversation.kind == .direct {
            return "\u{201c}\(name)\u{201d}, its workspace, and its direct conversation will be permanently deleted. It will also be removed from every group. This cannot be undone."
        }
        return "\u{201c}\(name)\u{201d}, its messages, and its attachments will be permanently deleted. The bots in the group will not be deleted. This cannot be undone."
    }

    func sendDraft() {
        guard let conversation = selectedConversation else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !pendingAttachments.isEmpty else { return }
        let messageBody = body.isEmpty ? "Sent \(pendingAttachments.count) attachment\(pendingAttachments.count == 1 ? "" : "s")" : body

        let message = ChatMessage(
            conversationID: conversation.id,
            author: .user,
            body: messageBody,
            delivery: .delivered,
            attachmentIDs: pendingAttachments.map(\.id)
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
            pendingAttachments = []
            runtime.notify(participants(for: conversation), repository: repository)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func messages(for conversation: BotConversation) -> [ChatMessage] {
        messagesByConversation[conversation.id, default: []]
    }

    func attachments(for message: ChatMessage) -> [ConversationAttachment] {
        let all = attachmentsByConversation[message.conversationID, default: []]
        let ids = Set(message.attachments)
        return all.filter { ids.contains($0.id) }
    }

    func importAttachment(from url: URL) {
        guard let conversation = selectedConversation else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let attachment = try repository.importAttachment(
                from: url,
                into: conversation.id,
                mediaType: mediaType
            )
            attachmentsByConversation[conversation.id, default: []].append(attachment)
            pendingAttachments.append(attachment)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removePendingAttachment(_ attachment: ConversationAttachment) {
        do {
            try repository.removeAttachment(attachment)
            pendingAttachments.removeAll { $0.id == attachment.id }
            attachmentsByConversation[attachment.conversationID, default: []].removeAll {
                $0.id == attachment.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealAttachment(_ attachment: ConversationAttachment) {
        NSWorkspace.shared.activateFileViewerSelecting([repository.attachmentFileURL(attachment)])
    }

    func refreshTranscripts() {
        do {
            let latestConversations = try repository.loadConversations()
            var latestMessages: [UUID: [ChatMessage]] = [:]
            var latestAttachments: [UUID: [ConversationAttachment]] = [:]
            for conversation in latestConversations {
                latestMessages[conversation.id] = try repository.loadMessages(conversationID: conversation.id)
                latestAttachments[conversation.id] = try repository.loadAttachments(conversationID: conversation.id)
            }
            if latestConversations != conversations { conversations = latestConversations }
            if latestMessages != messagesByConversation { messagesByConversation = latestMessages }
            if latestAttachments != attachmentsByConversation { attachmentsByConversation = latestAttachments }
        } catch {
            errorMessage = error.localizedDescription
        }
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

    func startAgents() {
        runtime.startAll(agents: agents, repository: repository)
        runtime.refreshCapabilities()
    }
}
