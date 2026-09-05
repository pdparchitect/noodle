import AppKit
import Foundation
import Observation
import SuperBotCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class SuperBotStore {
    private(set) static var active: SuperBotStore?

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
    private(set) var unreadConversationIDs: Set<UUID> = []
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
    private var transcriptRefreshTask: Task<Void, Never>?

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
        Self.active = self
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
            let knownConversationIDs = Set(conversations.map(\.id))
            let storedUnreadIDs = try repository.loadUnreadConversationIDs()
            unreadConversationIDs = storedUnreadIDs.intersection(knownConversationIDs)
            if unreadConversationIDs != storedUnreadIDs {
                try repository.saveUnreadConversationIDs(unreadConversationIDs)
            }
            runtime.refresh(agents: agents)
            refreshAppShortcuts()

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
        reasoningEffort: String?,
        avatarSymbolName: String?,
        avatarColorIndex: Int,
        avatarImageData: Data?,
        backstory: String
    ) -> Bool {
        do {
            let created = try repository.createAgent(
                named: name,
                harnessIdentifier: harnessIdentifier,
                modelIdentifier: modelIdentifier,
                reasoningEffort: reasoningEffort,
                avatarSymbolName: avatarSymbolName,
                avatarColorIndex: avatarColorIndex,
                avatarImageData: avatarImageData,
                backstory: backstory
            )
            agents.append(created.agent)
            conversations.insert(created.conversation, at: 0)
            messagesByConversation[created.conversation.id] = []
            attachmentsByConversation[created.conversation.id] = []
            runtime.refresh(agents: agents)
            runtime.start(agent: created.agent, repository: repository)
            selectedConversationID = created.conversation.id
            creationSheet = nil
            refreshAppShortcuts()
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
        reasoningEffort: String?,
        avatarSymbolName: String?,
        avatarColorIndex: Int,
        avatarImageData: Data?,
        backstory: String
    ) -> Bool {
        do {
            let previousBackstory = try repository.loadAgentBackstory(agent)
            let updated = try repository.updateAgent(
                agent,
                displayName: name,
                harnessIdentifier: harnessIdentifier,
                modelIdentifier: modelIdentifier,
                reasoningEffort: reasoningEffort,
                avatarSymbolName: avatarSymbolName,
                avatarColorIndex: avatarColorIndex,
                avatarImageData: avatarImageData
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

            try repository.updateAgentBackstory(updated, backstory: backstory)
            try repository.synchronizeAgentWorkspace(updated)
            runtime.restart(
                agent: updated,
                repository: repository,
                resetThread: previousBackstory != backstory.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            agentBeingEdited = nil
            refreshAppShortcuts()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func backstory(for agent: AgentRecord) -> String {
        do {
            return try repository.loadAgentBackstory(agent)
        } catch {
            errorMessage = error.localizedDescription
            return ""
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
            refreshAppShortcuts()
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
            refreshAppShortcuts()
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

        do {
            let message = try repository.sendUserMessage(
                conversationID: conversation.id,
                body: messageBody,
                attachmentIDs: pendingAttachments.map(\.id)
            )
            messagesByConversation[conversation.id, default: []].append(message)

            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index].updatedAt = message.createdAt
                conversations.sort { $0.updatedAt > $1.updatedAt }
            }

            draft = ""
            pendingAttachments = []
            runtime.notify(participants(for: conversation), repository: repository)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func sendCommand(_ command: String, to conversationID: UUID) throws -> ChatMessage {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let message = try repository.sendUserMessage(
            conversationID: conversation.id,
            body: command
        )
        messagesByConversation[conversation.id, default: []].append(message)
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].updatedAt = message.createdAt
            conversations.sort { $0.updatedAt > $1.updatedAt }
        }
        runtime.notify(participants(for: conversation), repository: repository)
        return message
    }

    func messages(for conversation: BotConversation) -> [ChatMessage] {
        messagesByConversation[conversation.id, default: []]
    }

    func hasUnreadMessages(in conversation: BotConversation) -> Bool {
        unreadConversationIDs.contains(conversation.id)
    }

    func markConversationRead(_ conversationID: UUID?) {
        guard let conversationID,
              unreadConversationIDs.remove(conversationID) != nil else { return }
        persistUnreadConversationIDs()
    }

    func markSelectedConversationReadIfVisible() {
        guard !SuperBotNotifications.shouldPresentActivity else { return }
        markConversationRead(selectedConversationID)
    }

    func attachments(for message: ChatMessage) -> [ConversationAttachment] {
        let all = attachmentsByConversation[message.conversationID, default: []]
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return message.attachments.compactMap { byID[$0] }
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
        NSWorkspace.shared.activateFileViewerSelecting([attachmentFileURL(attachment)])
    }

    func attachmentFileURL(_ attachment: ConversationAttachment) -> URL {
        repository.attachmentFileURL(attachment)
    }

    func refreshTranscripts() {
        do {
            let knownMessageIDs = Set(
                messagesByConversation.values.flatMap { messages in
                    messages.map(\.id)
                }
            )
            let latestConversations = try repository.loadConversations()
            var latestMessages: [UUID: [ChatMessage]] = [:]
            var latestAttachments: [UUID: [ConversationAttachment]] = [:]
            for conversation in latestConversations {
                latestMessages[conversation.id] = try repository.loadMessages(conversationID: conversation.id)
                latestAttachments[conversation.id] = try repository.loadAttachments(conversationID: conversation.id)
            }
            let newAgentMessages = latestMessages.values
                .flatMap { $0 }
                .filter { message in
                    guard !knownMessageIDs.contains(message.id) else { return false }
                    if case .agent = message.author { return true }
                    return false
                }
                .sorted { $0.createdAt < $1.createdAt }

            if latestConversations != conversations { conversations = latestConversations }
            if latestMessages != messagesByConversation { messagesByConversation = latestMessages }
            if latestAttachments != attachmentsByConversation { attachmentsByConversation = latestAttachments }
            registerUnreadMessages(newAgentMessages)
            postNotifications(for: newAgentMessages)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func participants(for conversation: BotConversation) -> [AgentRecord] {
        conversation.participantIDs.compactMap { id in
            agents.first(where: { $0.id == id })
        }
    }

    private func refreshAppShortcuts() {
        SuperBotShortcuts.updateAppShortcutParameters()
    }

    private func registerUnreadMessages(_ messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }

        var updated = unreadConversationIDs
        let isViewingSelectedConversation = !SuperBotNotifications.shouldPresentActivity
        for message in messages {
            if isViewingSelectedConversation && message.conversationID == selectedConversationID {
                updated.remove(message.conversationID)
            } else {
                updated.insert(message.conversationID)
            }
        }

        guard updated != unreadConversationIDs else { return }
        unreadConversationIDs = updated
        persistUnreadConversationIDs()
    }

    private func persistUnreadConversationIDs() {
        do {
            try repository.saveUnreadConversationIDs(unreadConversationIDs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func postNotifications(for messages: [ChatMessage]) {
        guard SuperBotNotifications.shouldPresentActivity else { return }

        for message in messages {
            guard case .agent(let agentID) = message.author,
                  let agent = agents.first(where: { $0.id == agentID }),
                  let conversation = conversations.first(where: { $0.id == message.conversationID }) else {
                continue
            }
            SuperBotNotifications.post(
                message: message,
                from: agent,
                in: conversation
            )
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

    func startMonitoring() {
        guard transcriptRefreshTask == nil else { return }
        startAgents()
        transcriptRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.refreshTranscripts()
            }
        }
    }

    func stopMonitoring() {
        transcriptRefreshTask?.cancel()
        transcriptRefreshTask = nil
        runtime.stopAll()
    }
}
