import AppKit
import Foundation
import Observation
import NoodleCore
import UniformTypeIdentifiers

private struct TranscriptSnapshot: Sendable {
    let conversations: [BotConversation]
    let messages: [UUID: [ChatMessage]]
    let attachments: [UUID: [ConversationAttachment]]
    let conversationsChanged: Bool
    let messagesChanged: Bool
    let attachmentsChanged: Bool
    let revisions: [UUID: TranscriptRevision]
}

private struct TranscriptRevision: Equatable, Sendable {
    let messagesModifiedAt: Date?
    let messagesSize: UInt64?
    let attachmentsModifiedAt: Date?
}

@MainActor
@Observable
final class NoodleStore {
    private(set) static var active: NoodleStore?

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
    private(set) var messagesByConversation: [UUID: [ChatMessage]] = [:] {
        didSet { transcriptGeneration &+= 1 }
    }
    private(set) var attachmentsByConversation: [UUID: [ConversationAttachment]] = [:] {
        didSet {
            transcriptGeneration &+= 1
            attachmentLookupByConversation = attachmentsByConversation.mapValues { attachments in
                Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
            }
        }
    }
    private(set) var unreadConversationIDs: Set<UUID> = [] {
        didSet { updateDockBadge() }
    }
    var selectedConversationID: UUID?
    var searchText = ""
    private var drafts = ConversationDrafts()
    var draft: String {
        get { selectedConversationID.map { drafts[$0].text } ?? "" }
        set {
            guard let selectedConversationID else { return }
            drafts[selectedConversationID].text = newValue
        }
    }

    func draft(for conversationID: UUID) -> String {
        drafts[conversationID].text
    }

    func setDraft(_ text: String, for conversationID: UUID) {
        drafts[conversationID].text = text
    }
    var creationSheet: CreationSheet?
    var selectedSettingsTab: NoodleSettingsTab = .general
    var agentBeingEdited: AgentRecord?
    var groupBeingEdited: BotConversation?
    var backgroundBeingEdited: BotConversation?
    private(set) var backgrounds: [UUID: ConversationBackground] = [:]
    var errorMessage: String?
    private(set) var storageReady = false
    var pendingAttachments: [ConversationAttachment] {
        get { selectedConversationID.map { drafts[$0].attachments } ?? [] }
        set {
            guard let selectedConversationID else { return }
            drafts[selectedConversationID].attachments = newValue
        }
    }
    var composerIsFocused = false
    @ObservationIgnored private var voiceRecorders: [UUID: AnyObject] = [:]

    @available(macOS 26.0, *)
    func voiceRecorder(for conversationID: UUID) -> VoiceRecorder {
        if let recorder = voiceRecorders[conversationID] as? VoiceRecorder { return recorder }
        let recorder = VoiceRecorder(directory: repository.attachmentsDirectory(conversationID: conversationID)
            .appendingPathComponent("VoiceDraft", isDirectory: true))
        voiceRecorders[conversationID] = recorder
        return recorder
    }

    let repository: WorkspaceRepository
    @ObservationIgnored private let transcriptPositions: TranscriptPositionStore
    let mcp: MCPController
    let computers: ComputerController
    let applets: AppletController
    let runtime = AgentRuntimeCoordinator()
    private var transcriptRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptGeneration: UInt = 0
    private var attachmentLookupByConversation: [UUID: [UUID: ConversationAttachment]] = [:]
    @ObservationIgnored private var transcriptRevisions: [UUID: TranscriptRevision] = [:]
    private var isProcessingShares = false
    private var failedShareIDs: Set<UUID> = []

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
                rootURL: applicationSupport.appendingPathComponent("Noodle", isDirectory: true),
                launcherExecutableURL: FileManager.default.isExecutableFile(atPath: bundledMessenger.path)
                    ? bundledMessenger
                    : Bundle.main.executableURL
            )
        }

        transcriptPositions = TranscriptPositionStore(fileURL: self.repository.rootURL.appendingPathComponent("scroll-positions.json"))
        mcp = MCPController(repository: self.repository)
        computers = ComputerController(repository: self.repository)
        applets = AppletController(repository: self.repository)
        reload()
        Self.active = self
    }

    var selectedConversation: BotConversation? {
        conversations.first(where: { $0.id == selectedConversationID })
    }

    var canCreateBot: Bool { storageReady && !runtime.availableInstallations.isEmpty }

    func showNewBot() {
        guard canCreateBot else { return }
        creationSheet = .bot
    }

    var filteredConversations: [BotConversation] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return conversations }

        return conversations.filter { conversation in
            title(for: conversation).localizedCaseInsensitiveContains(term) ||
                (conversation.publicDescription?.localizedCaseInsensitiveContains(term) ?? false) ||
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
        storageReady = false
        do {
            try repository.prepare()
            let migratedIDs = Set(try repository.migrateAgentStorage())
            agents = try repository.loadAgents()
            runtime.prepareAccessForExistingAgents(agents, migratedIDs: migratedIDs)
            try repository.synchronizeAgentWorkspaces(agents)
            mcp.start(agents: agents)
            computers.start(agents: agents)
            applets.start(agents: agents)
            conversations = try repository.loadConversations()
            backgrounds = Dictionary(uniqueKeysWithValues: conversations.map {
                ($0.id, (try? repository.loadBackground(conversationID: $0.id)) ?? ConversationBackground())
            })
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
            transcriptRevisions = Dictionary(uniqueKeysWithValues: conversations.map {
                ($0.id, Self.transcriptRevision(for: $0.id, repository: repository))
            })
            for conversation in conversations {
                drafts.restoreAnnotations(attachmentsByConversation[conversation.id, default: []],
                    messages: messagesByConversation[conversation.id, default: []], conversationID: conversation.id)
            }
            let knownConversationIDs = Set(conversations.map(\.id))
            drafts.retainConversations(knownConversationIDs)
            try? transcriptPositions.retainConversations(knownConversationIDs)
            let storedUnreadIDs = try repository.loadUnreadConversationIDs()
            unreadConversationIDs = storedUnreadIDs.intersection(knownConversationIDs)
            if unreadConversationIDs != storedUnreadIDs {
                try repository.saveUnreadConversationIDs(unreadConversationIDs)
            }
            runtime.refresh(agents: agents)
            refreshAppShortcuts()
            storageReady = true

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
        publicDescription: String,
        backstory: String,
        mcpConnectionIDs: Set<UUID> = [],
        computerIDs: Set<UUID> = []
    ) -> Bool {
        guard runtime.availableInstallations.contains(where: { $0.provider.rawValue == harnessIdentifier }) else {
            errorMessage = "Set up a supported harness in Settings before creating a bot."
            return false
        }
        do {
            try mcp.validateAssignment(mcpConnectionIDs)
            try computers.validate(computerIDs)
            runtime.prepareAccessForExistingAgents(agents)
            let created = try repository.createAgent(
                named: name,
                harnessIdentifier: harnessIdentifier,
                modelIdentifier: modelIdentifier,
                reasoningEffort: reasoningEffort,
                publicDescription: publicDescription,
                avatarSymbolName: avatarSymbolName,
                avatarColorIndex: avatarColorIndex,
                avatarImageData: avatarImageData,
                backstory: backstory
            )
            agents.append(created.agent)
            runtime.authorizeSelectedHarness(created.agent)
            conversations.insert(created.conversation, at: 0)
            messagesByConversation[created.conversation.id] = []
            attachmentsByConversation[created.conversation.id] = []
            try mcp.assign(mcpConnectionIDs, to: created.agent)
            try computers.assign(computerIDs, to: created.agent)
            computers.start(agents: agents)
            applets.start(agents: agents)
            mcp.start(agents: agents)
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
        publicDescription: String,
        backstory: String,
        mcpConnectionIDs: Set<UUID>? = nil,
        computerIDs: Set<UUID>? = nil
    ) -> Bool {
        do {
            if let mcpConnectionIDs { try mcp.validateAssignment(mcpConnectionIDs) }
            if let computerIDs { try computers.validate(computerIDs) }
            let previousBackstory = try repository.loadAgentBackstory(agent)
            let updated = try repository.updateAgent(
                agent,
                displayName: name,
                harnessIdentifier: harnessIdentifier,
                modelIdentifier: modelIdentifier,
                reasoningEffort: reasoningEffort,
                publicDescription: publicDescription,
                avatarSymbolName: avatarSymbolName,
                avatarColorIndex: avatarColorIndex,
                avatarImageData: avatarImageData
            )
            if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                agents[index] = updated
            }
            runtime.authorizeSelectedHarness(updated)

            for index in conversations.indices where
                conversations[index].kind == .direct &&
                conversations[index].participantIDs == [agent.id] {
                conversations[index].displayName = updated.displayName
                conversations[index].updatedAt = updated.updatedAt
                try repository.updateConversation(conversations[index])
            }

            try repository.updateAgentBackstory(updated, backstory: backstory)
            if let mcpConnectionIDs { try mcp.assign(mcpConnectionIDs, to: updated) }
            if let computerIDs { try computers.assign(computerIDs, to: updated) }
            computers.start(agents: agents)
            applets.start(agents: agents)
            try repository.synchronizeAgentWorkspace(updated)
            mcp.start(agents: agents)
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

    func createGroup(named name: String, publicDescription: String, participantIDs: Set<UUID>) -> Bool {
        do {
            let conversation = try repository.createGroup(
                named: name,
                publicDescription: publicDescription,
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

    func updateGroup(
        _ conversation: BotConversation,
        named name: String,
        publicDescription: String,
        participantIDs: Set<UUID>
    ) -> Bool {
        do {
            let membershipChanged = participantIDs != Set(conversation.participantIDs)
            let normalizedDescription = publicDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let descriptionChanged = (conversation.publicDescription ?? "") != normalizedDescription
            let updated = try repository.updateGroup(
                conversationID: conversation.id,
                named: name,
                publicDescription: publicDescription,
                participantIDs: Array(participantIDs),
                existingAgents: agents
            )
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index] = updated
                conversations.sort { $0.updatedAt > $1.updatedAt }
            }
            if membershipChanged || descriptionChanged {
                messagesByConversation[conversation.id] = try repository.loadMessages(
                    conversationID: conversation.id
                )
                runtime.notify(participants(for: updated), repository: repository)
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

            drafts.clear(conversation.id)
            if selectedConversationID == conversation.id {
                selectedConversationID = nil
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

    func sendVoiceMessage(from url: URL, voice: VoiceMessage, to conversationID: UUID) throws {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let attachment = try repository.importAttachment(from: url, into: conversationID, mediaType: "audio/x-caf", voice: voice)
        attachmentsByConversation[conversationID, default: []].append(attachment)
        let message = try repository.sendUserMessage(conversationID: conversationID,
            body: VoiceMessage.messageBody, attachmentIDs: [attachment.id])
        messagesByConversation[conversationID, default: []].append(message)
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].updatedAt = message.createdAt
            conversations.sort { $0.updatedAt > $1.updatedAt }
        }
        // Existing text and file drafts are independent and remain untouched.
        runtime.notify(participants(for: conversation), repository: repository)
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

            drafts.clear(conversation.id)
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

    func transcriptViewport(for conversation: BotConversation) -> TranscriptViewport {
        transcriptPositions.viewport(for: conversation.id)
            .restored(availableMessageIDs: Set(messages(for: conversation).map(\.id)))
    }

    func saveTranscriptViewport(_ viewport: TranscriptViewport, for conversationID: UUID) {
        guard conversations.contains(where: { $0.id == conversationID }) else { return }
        do { try transcriptPositions.save(viewport, for: conversationID) }
        catch { errorMessage = "Could not save the conversation’s reading position: \(error.localizedDescription)" }
    }

    func hasUnreadMessages(in conversation: BotConversation) -> Bool {
        unreadConversationIDs.contains(conversation.id)
    }

    func updateDockBadge() {
        NSApplication.shared.dockTile.badgeLabel = unreadConversationIDs.isEmpty
            ? nil
            : String(unreadConversationIDs.count)
    }

    func markConversationRead(_ conversationID: UUID?) {
        guard let conversationID,
              unreadConversationIDs.remove(conversationID) != nil else { return }
        persistUnreadConversationIDs()
    }

    func markSelectedConversationReadIfVisible() {
        guard !NoodleNotifications.shouldPresentActivity else { return }
        markConversationRead(selectedConversationID)
    }

    func attachments(for message: ChatMessage) -> [ConversationAttachment] {
        let byID = attachmentLookupByConversation[message.conversationID, default: [:]]
        return message.attachments.compactMap { byID[$0] }
    }

    func importAttachment(from url: URL) {
        guard let conversationID = selectedConversation?.id else { return }
        importAttachment(from: url, into: conversationID)
    }

    func importAttachment(from url: URL, into conversationID: UUID) {
        do {
            try importAttachmentFile(from: url, into: conversationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importAttachments(from providers: [NSItemProvider]) {
        guard let conversationID = selectedConversation?.id else { return }

        Task {
            var firstError: Error?
            for provider in providers {
                do {
                    let payload = try await AttachmentTransfer.load(provider)
                    guard conversations.contains(where: { $0.id == conversationID }) else { return }
                    switch payload {
                    case .file(let url):
                        try importAttachmentFile(from: url, into: conversationID)
                    case .data(let data, let originalFilename, let mediaType):
                        try importAttachment(
                            data: data,
                            originalFilename: originalFilename,
                            mediaType: mediaType,
                            into: conversationID
                        )
                    }
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                errorMessage = firstError.localizedDescription
            }
        }
    }

    func importAttachmentsFromPasteboard() -> Bool {
        guard let conversationID = selectedConversation?.id else { return false }
        let pasteboard = NSPasteboard.general

        let values = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !values.isEmpty {
            var imported = false
            for value in values {
                do {
                    try importAttachmentFile(from: value, into: conversationID)
                    imported = true
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return imported
        }

        if let pngData = pasteboard.data(forType: .png) {
            do {
                try importAttachment(
                    data: pngData,
                    originalFilename: "Pasted Image.png",
                    mediaType: "image/png",
                    into: conversationID
                )
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }

        if let tiffData = pasteboard.data(forType: .tiff) {
            do {
                try importAttachment(
                    data: tiffData,
                    originalFilename: "Pasted Image.tiff",
                    mediaType: "image/tiff",
                    into: conversationID
                )
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }

        return false
    }

    func importPhoto(data: Data, into conversationID: UUID) throws {
        let payload = try AttachmentTransfer.photoPayload(data)
        if case .data(let data, let filename, let mediaType) = payload {
            try importAttachment(data: data, originalFilename: filename, mediaType: mediaType, into: conversationID)
        }
    }

    func importCapture(image: CGImage, title: String, region: AttachmentAnnotation.Region?, comment: String,
                       into conversationID: UUID) throws {
        let saved = try CaptureAttachment.save(image: image, title: title, region: region, comment: comment,
                                               into: conversationID, repository: repository)
        if let source = saved.source { attachmentsByConversation[conversationID, default: []].append(source) }
        attachmentsByConversation[conversationID, default: []].append(saved.attachment)
        drafts[conversationID].attachments.append(saved.attachment)
    }

    private func importAttachmentFile(from url: URL, into conversationID: UUID) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let attachment = try repository.importAttachment(
            from: url,
            into: conversationID,
            mediaType: mediaType
        )
        attachmentsByConversation[conversationID, default: []].append(attachment)
        drafts[conversationID].attachments.append(attachment)
    }

    private func importAttachment(
        data: Data,
        originalFilename: String,
        mediaType: String,
        into conversationID: UUID
    ) throws {
        let attachment = try repository.importAttachment(
            data: data,
            originalFilename: originalFilename,
            into: conversationID,
            mediaType: mediaType
        )
        attachmentsByConversation[conversationID, default: []].append(attachment)
        drafts[conversationID].attachments.append(attachment)
    }

    /// Save to the originating draft even if the selected conversation changed.
    func saveAnnotation(_ annotation: AttachmentAnnotation, content: Data, source: ConversationAttachment) throws {
        guard conversations.contains(where: { $0.id == source.conversationID }) else {
            throw WorkspaceError.missingConversation(source.conversationID)
        }
        let stem = URL(fileURLWithPath: source.originalFilename).deletingPathExtension().lastPathComponent
        let attachment = try repository.importAttachment(data: content,
            originalFilename: "Annotation — \(stem.prefix(160)).\(annotation.fileExtension)", into: source.conversationID,
            mediaType: annotation.mediaType, annotation: annotation)
        attachmentsByConversation[source.conversationID, default: []].append(attachment)
        drafts[source.conversationID].attachments.append(attachment)
    }

    func saveConversationAnnotation(_ note: AttachmentAnnotation, content: Data,
                                    source: ConversationAttachment, sourceData: Data) throws {
        let saved = try ConversationAnnotationContent.save(note, content: content, source: source,
            sourceData: sourceData, repository: repository)
        let id = source.conversationID
        attachmentsByConversation[id, default: []].append(contentsOf: [saved.source, saved.attachment])
        drafts[id].attachments.append(saved.attachment)
    }

    func canEditAnnotation(_ attachment: ConversationAttachment) -> Bool {
        drafts.canEditAnnotation(attachment, messages: messagesByConversation[attachment.conversationID, default: []])
    }

    func reviseAnnotationComment(_ attachment: ConversationAttachment, comment: String) throws -> ConversationAttachment {
        guard canEditAnnotation(attachment), let annotation = attachment.annotation else { throw WorkspaceError.invalidAttachment }
        let updated = try repository.reviseAnnotationComment(attachment, comment: comment,
            content: AnnotationContent.editedData(for: annotation.replacingComment(comment), originalURL: attachmentFileURL(attachment)))
        let conversationID = updated.conversationID
        if let index = attachmentsByConversation[conversationID, default: []].firstIndex(where: { $0.id == updated.id }) {
            attachmentsByConversation[conversationID]![index] = updated
        } else { attachmentsByConversation[conversationID, default: []].append(updated) }
        if let index = drafts[conversationID].attachments.firstIndex(where: { $0.id == updated.id }) {
            drafts[conversationID].attachments[index] = updated
        }
        return updated
    }

    func removePendingAttachment(_ attachment: ConversationAttachment) {
        do {
            try repository.removeAttachment(attachment)
            drafts[attachment.conversationID].attachments.removeAll { $0.id == attachment.id }
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

    func copyAttachment(_ attachment: ConversationAttachment) {
        let url = attachmentFileURL(attachment)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if attachment.mediaType.hasPrefix("image/"),
           let image = NSImage(contentsOf: url),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setData(pngData, forType: .png)
            item.setData(tiffData, forType: .tiff)
            if pasteboard.writeObjects([item]) { return }
            pasteboard.clearContents()
        }

        if pasteboard.writeObjects([url as NSURL]) {
            return
        }

        errorMessage = "The attachment could not be copied."
    }

    func attachmentFileURL(_ attachment: ConversationAttachment) -> URL {
        repository.attachmentFileURL(attachment)
    }

    func refreshTranscripts() {
        do {
            applyTranscriptSnapshot(try Self.loadTranscriptSnapshot(
                from: repository,
                currentConversations: conversations,
                currentMessages: messagesByConversation,
                currentAttachments: attachmentsByConversation,
                currentRevisions: transcriptRevisions
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshTranscriptsInBackground() async {
        let generation = transcriptGeneration
        let repository = repository
        let currentConversations = conversations
        let currentMessages = messagesByConversation
        let currentAttachments = attachmentsByConversation
        let currentRevisions = transcriptRevisions
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try Self.loadTranscriptSnapshot(
                    from: repository,
                    currentConversations: currentConversations,
                    currentMessages: currentMessages,
                    currentAttachments: currentAttachments,
                    currentRevisions: currentRevisions
                )
            }.value
            guard !Task.isCancelled, generation == transcriptGeneration else { return }
            applyTranscriptSnapshot(snapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated private static func loadTranscriptSnapshot(
        from repository: WorkspaceRepository,
        currentConversations: [BotConversation],
        currentMessages: [UUID: [ChatMessage]],
        currentAttachments: [UUID: [ConversationAttachment]],
        currentRevisions: [UUID: TranscriptRevision]
    ) throws -> TranscriptSnapshot {
        let conversations = try repository.loadConversations()
        var messages: [UUID: [ChatMessage]] = [:]
        var attachments: [UUID: [ConversationAttachment]] = [:]
        var revisions: [UUID: TranscriptRevision] = [:]
        let conversationIDs = Set(conversations.map(\.id))
        var messagesChanged = Set(currentMessages.keys) != conversationIDs
        var attachmentsChanged = Set(currentAttachments.keys) != conversationIDs
        for conversation in conversations {
            let revision = transcriptRevision(for: conversation.id, repository: repository)
            revisions[conversation.id] = revision
            if revision.messagesModifiedAt == currentRevisions[conversation.id]?.messagesModifiedAt,
               revision.messagesSize == currentRevisions[conversation.id]?.messagesSize,
               let current = currentMessages[conversation.id] {
                messages[conversation.id] = current
            } else {
                messages[conversation.id] = try repository.loadMessages(conversationID: conversation.id)
                messagesChanged = true
            }
            if revision.attachmentsModifiedAt == currentRevisions[conversation.id]?.attachmentsModifiedAt,
               let current = currentAttachments[conversation.id] {
                attachments[conversation.id] = current
            } else {
                attachments[conversation.id] = try repository.loadAttachments(conversationID: conversation.id)
                attachmentsChanged = true
            }
        }
        return TranscriptSnapshot(
            conversations: conversations,
            messages: messages,
            attachments: attachments,
            conversationsChanged: conversations != currentConversations,
            messagesChanged: messagesChanged,
            attachmentsChanged: attachmentsChanged,
            revisions: revisions
        )
    }

    nonisolated private static func transcriptRevision(
        for conversationID: UUID,
        repository: WorkspaceRepository
    ) -> TranscriptRevision {
        let fileManager = FileManager.default
        let messagesURL = repository.conversationDirectory(id: conversationID)
            .appendingPathComponent("messages.json")
        let messageAttributes = try? fileManager.attributesOfItem(atPath: messagesURL.path)
        let attachmentAttributes = try? fileManager.attributesOfItem(
            atPath: repository.attachmentsDirectory(conversationID: conversationID).path
        )
        return TranscriptRevision(
            messagesModifiedAt: messageAttributes?[.modificationDate] as? Date,
            messagesSize: (messageAttributes?[.size] as? NSNumber)?.uint64Value,
            attachmentsModifiedAt: attachmentAttributes?[.modificationDate] as? Date
        )
    }

    private func applyTranscriptSnapshot(_ snapshot: TranscriptSnapshot) {
        transcriptRevisions = snapshot.revisions
        guard snapshot.conversationsChanged || snapshot.messagesChanged || snapshot.attachmentsChanged else { return }

        let newAgentMessages: [ChatMessage]
        let reactionChanges: [MessageReactionChange]
        if snapshot.messagesChanged {
            let knownMessageIDs = Set(messagesByConversation.values.flatMap { $0.map(\.id) })
            let knownReactionIDs = Set(messagesByConversation.values.flatMap { $0 }
                .flatMap { $0.reactionChanges ?? [] }.map(\.id))
            newAgentMessages = snapshot.messages.values
                .flatMap { $0 }
                .filter { message in
                    guard !knownMessageIDs.contains(message.id) else { return false }
                    if case .agent = message.author { return true }
                    return false
                }
                .sorted { $0.createdAt < $1.createdAt }
            reactionChanges = snapshot.messages.values.flatMap { $0 }
                .flatMap { $0.reactionChanges ?? [] }.filter { !knownReactionIDs.contains($0.id) }
        } else {
            newAgentMessages = []
            reactionChanges = []
        }

        if snapshot.conversationsChanged { conversations = snapshot.conversations }
        if snapshot.messagesChanged { messagesByConversation = snapshot.messages }
        if snapshot.attachmentsChanged { attachmentsByConversation = snapshot.attachments }
        for message in newAgentMessages {
            if case .agent(let id) = message.author { runtime.recordActivity(for: id) }
        }
        notifyGroupParticipants(for: newAgentMessages)
        for change in reactionChanges {
            if case .agent(let id) = change.author { runtime.recordActivity(for: id) }
        }
        let reactionRecipientIDs = Set(reactionChanges.flatMap { change in
            (snapshot.conversations.first { $0.id == change.conversationID }?.participantIDs ?? [])
                .filter { change.author != .agent($0) }
        })
        if !reactionRecipientIDs.isEmpty {
            runtime.notify(agents.filter { reactionRecipientIDs.contains($0.id) }, repository: repository)
        }
        registerUnreadMessages(newAgentMessages)
        postNotifications(for: newAgentMessages)
    }

    func participants(for conversation: BotConversation) -> [AgentRecord] {
        conversation.participantIDs.compactMap { id in
            agents.first(where: { $0.id == id })
        }
    }

    func toggleReaction(_ emoji: String, on message: ChatMessage) {
        do {
            let latest = try repository.loadMessages(conversationID: message.conversationID)
                .first { $0.id == message.id }
            let hasReaction = latest?.reactions?.contains { $0.author == .user && $0.emoji == emoji } ?? false
            try repository.setReaction(conversationID: message.conversationID, messageID: message.id,
                                       author: .user, emoji: emoji, present: !hasReaction)
            refreshTranscripts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeReaction(_ emoji: String, on message: ChatMessage) {
        do {
            try repository.setReaction(conversationID: message.conversationID, messageID: message.id,
                                       author: .user, emoji: emoji, present: false)
            refreshTranscripts()
        } catch { errorMessage = error.localizedDescription }
    }

    func background(for conversation: BotConversation?) -> ConversationBackground {
        guard let id = conversation?.id else { return ConversationBackground() }
        return backgrounds[id] ?? ConversationBackground()
    }

    func setBackground(_ background: ConversationBackground, imageData: Data?, file: PreparedBackgroundFile? = nil, for conversation: BotConversation) async throws {
        let repository = repository
        let saved = try await Task.detached {
            if let file { return try repository.setBackground(conversationID: conversation.id, file: file) }
            if let imageData { return try repository.setBackground(conversationID: conversation.id, imageData: imageData) }
            return try repository.setBackground(conversationID: conversation.id, preset: background.preset)
        }.value
        backgrounds[conversation.id] = saved
    }

    func useAttachmentAsBackground(_ attachment: ConversationAttachment) async {
        let repository = repository
        do {
            let saved = try await Task.detached {
                try repository.setBackground(from: attachment)
            }.value
            // Keep the action bound to its source chat even if selection changes during decoding.
            backgrounds[attachment.conversationID] = saved
        } catch { errorMessage = error.localizedDescription }
    }

    func useAttachmentAsIcon(_ attachment: ConversationAttachment) async {
        let repository = repository
        do {
            let updated = try await Task.detached {
                try repository.setAgentIcon(from: attachment)
            }.value
            if let index = agents.firstIndex(where: { $0.id == updated.id }) { agents[index] = updated }
            refreshAppShortcuts()
        } catch { errorMessage = error.localizedDescription }
    }

    func changeReaction(_ emoji: String, to replacement: String, on message: ChatMessage) {
        guard emoji != replacement else { return }
        do {
            // Add first so a failed write cannot silently lose the existing reaction.
            // Idempotent writes preserve an already-present replacement and other people's badges.
            try repository.setReaction(conversationID: message.conversationID, messageID: message.id,
                                       author: .user, emoji: replacement, present: true)
            try repository.setReaction(conversationID: message.conversationID, messageID: message.id,
                                       author: .user, emoji: emoji, present: false)
            refreshTranscripts()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshAppShortcuts() {
        NoodleShortcuts.updateAppShortcutParameters()
        publishShareDestinations()
    }

    func publishShareDestinations() {
        guard let inbox = try? SharedInbox.configured() else { return }
        try? inbox.saveDestinations(conversations.map {
            ShareDestination(id: $0.id, name: title(for: $0), isGroup: $0.kind == .group)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    func processSharedInbox() async {
        guard !isProcessingShares, let inbox = try? SharedInbox.configured() else { return }
        isProcessingShares = true
        defer { isProcessingShares = false }
        let repository = repository
        do {
            let pending = try await Task.detached { try inbox.pending() }.value
            for request in pending where !failedShareIDs.contains(request.id) {
                do {
                    let message = try await Task.detached {
                        try repository.sendSharedMessage(request, files: inbox.files(for: request))
                    }.value
                    refreshTranscripts()
                    if let conversation = conversations.first(where: { $0.id == message.conversationID }) {
                        runtime.notify(participants(for: conversation), repository: repository)
                    }
                    try await Task.detached { try inbox.acknowledge(request.id) }.value
                } catch {
                    failedShareIDs.insert(request.id)
                    errorMessage = "Could not deliver a shared item: \(error.localizedDescription) The item is retained for retry when Noodle restarts."
                }
            }
        } catch { errorMessage = "Could not read shared items: \(error.localizedDescription)" }
    }

    private func notifyGroupParticipants(for messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }

        do {
            let recipientIDs = try repository.notificationRecipientIDs(for: messages)
            let recipients = agents.filter { recipientIDs.contains($0.id) }
            if !recipients.isEmpty {
                runtime.notify(recipients, repository: repository)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func registerUnreadMessages(_ messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }

        var updated = unreadConversationIDs
        let isViewingSelectedConversation = !NoodleNotifications.shouldPresentActivity
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
        guard NoodleNotifications.shouldPresentActivity else { return }

        for message in messages {
            guard case .agent(let agentID) = message.author,
                  let agent = agents.first(where: { $0.id == agentID }),
                  let conversation = conversations.first(where: { $0.id == message.conversationID }) else {
                continue
            }
            NoodleNotifications.post(
                message: message,
                from: agent,
                in: conversation
            )
        }
    }

    func title(for conversation: BotConversation) -> String {
        if conversation.kind == .direct,
           let agent = participants(for: conversation).first {
            return ConversationName.display(agent.displayName)
        }
        return ConversationName.display(conversation.displayName)
    }

    func preview(for conversation: BotConversation) -> String {
        guard let body = messages(for: conversation).last?.body else { return "No messages yet" }
        return MarkdownPlainText.convert(body)
    }

    func revealWorkspace(for agent: AgentRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([repository.directory(for: agent)])
    }

    func startAgents() {
        guard storageReady else { return }
        for agent in agents {
            let conversationIDs = Set(conversations.filter {
                $0.participantIDs.contains(agent.id)
            }.map(\.id))
            let latestMessageDate = messagesByConversation
                .filter { conversationIDs.contains($0.key) }
                .flatMap(\.value)
                .map(\.createdAt)
                .max()
            runtime.seedHeartbeatActivity(
                for: agent.id,
                at: latestMessageDate ?? agent.createdAt
            )
        }
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
                guard let self else { break }
                await self.refreshTranscriptsInBackground()
                await self.processSharedInbox()
                guard !Task.isCancelled else { break }
                self.runtime.reconcile(agents: self.agents, repository: self.repository)
                self.runtime.checkHeartbeats()
            }
        }
    }

    func recoverAgentsAfterWake() {
        runtime.reconcile(agents: agents, repository: repository, immediately: true)
    }

    func stopMonitoring() {
        transcriptRefreshTask?.cancel()
        transcriptRefreshTask = nil
        runtime.stopAll()
    }
}
