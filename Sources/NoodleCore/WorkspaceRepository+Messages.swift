import Foundation
import UniformTypeIdentifiers

extension WorkspaceRepository {
    public func append(_ message: ChatMessage) throws {
        let file = conversationDirectory(id: message.conversationID).appendingPathComponent("messages.json")
        try withConversationLock(message.conversationID) {
            var messages = try loadMessages(conversationID: message.conversationID)
            messages.append(message)
            try write(messages, to: file)
        }
    }

    func inboxURL(for agentID: UUID) -> URL {
        // Mutable messaging state is not skill/configuration data. Codex keeps
        // .agents read-only even within a writable workspace.
        directory(forAgentID: agentID).appendingPathComponent(".noodle/inbox.json")
    }

    func loadInbox(for agentID: UUID) throws -> AgentInbox {
        let current = inboxURL(for: agentID)
        if FileManager.default.fileExists(atPath: current.path) {
            return try read(AgentInbox.self, from: current)
        }
        // Lazy migration: preserve the old cursor (including reaction offsets),
        // leave its file untouched, and write the new location only on consume.
        let legacy = directory(forAgentID: agentID).appendingPathComponent(".agents/inbox.json")
        if FileManager.default.fileExists(atPath: legacy.path) {
            return try read(AgentInbox.self, from: legacy)
        }
        return AgentInbox()
    }

    private func saveInbox(_ inbox: AgentInbox, for agentID: UUID) throws {
        let file = inboxURL(for: agentID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(inbox, to: file)
    }

    public func latestMessages(
        for agentID: UUID,
        consuming: Bool = true,
        in conversationID: UUID? = nil,
        includingRead: Bool = false,
        preparing: (([MessengerDelivery]) throws -> Void)? = nil
    ) throws -> [MessengerDelivery] {
        let agents = try loadAgents()
        guard let readingAgent = agents.first(where: { $0.id == agentID }) else {
            throw WorkspaceError.missingAgent(agentID)
        }
        let agentsByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let me = MessengerIdentity(handle: .me, agentID: agentID, displayName: readingAgent.displayName)
        let conversations = try loadConversations().filter {
            $0.participantIDs.contains(agentID) && (conversationID == nil || $0.id == conversationID)
        }
        if let conversationID, conversations.isEmpty { throw WorkspaceError.missingConversation(conversationID) }
        var inbox = try loadInbox(for: agentID)
        var deliveries: [MessengerDelivery] = []

        func identity(for author: MessageAuthor) -> MessengerIdentity {
            switch author {
            case .user: return MessengerIdentity(handle: .user, displayName: "User")
            case .agent(let id):
                return id == agentID ? me : MessengerIdentity(
                    handle: .bot, agentID: id,
                    displayName: agentsByID[id]?.displayName ?? "Unknown Bot"
                )
            case .system: return MessengerIdentity(handle: .system, displayName: "Noodle")
            }
        }

        for conversation in conversations {
            let messages = try loadMessages(conversationID: conversation.id)
            let key = conversation.id.uuidString.lowercased()
            let offset = includingRead ? 0 : min(inbox.conversationOffsets[key, default: 0], messages.count)
            let attachments = try loadAttachments(conversationID: conversation.id)
            let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
            let participants = conversation.participantIDs.map { participantID in
                if participantID == agentID { return me }
                return MessengerIdentity(
                    handle: .bot,
                    agentID: participantID,
                    displayName: agentsByID[participantID]?.displayName ?? "Unknown Bot"
                )
            }

            func delivery(for message: ChatMessage) -> MessengerDelivery {
                var delivery = MessengerDelivery(
                        me: me,
                        conversation: conversation,
                        participants: participants,
                        sender: identity(for: message.author),
                        message: message,
                        attachments: message.attachments.compactMap { attachmentID in
                            guard let attachment = byID[attachmentID] else { return nil }
                            return MessengerAttachment(
                                attachment: attachment,
                                absolutePath: attachmentFileURL(attachment).standardizedFileURL.path
                            )
                        }
                )
                delivery.reactions = (message.reactions ?? []).map {
                    MessengerReaction(emoji: $0.emoji, sender: identity(for: $0.author))
                }
                return delivery
            }

            for message in messages.dropFirst(offset) {
                if !includingRead, case .agent(let authorID) = message.author, authorID == agentID { continue }
                deliveries.append(delivery(for: message))
            }

            let changes = messages.flatMap { $0.reactionChanges ?? [] }
            let reactionOffset = inbox.reactionOffsets?[key] ?? 0
            if !includingRead {
                let byMessageID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
                for change in changes.sorted(by: { $0.sequence < $1.sequence }) where change.sequence > reactionOffset {
                    if change.author == .agent(agentID) { continue }
                    guard let message = byMessageID[change.messageID] else { continue }
                    var item = delivery(for: message)
                    item.reactionChange = MessengerReactionChange(
                        id: change.id, emoji: change.emoji, removed: change.removed,
                        sender: identity(for: change.author), createdAt: change.createdAt
                    )
                    deliveries.append(item)
                }
            }
            if consuming && !includingRead {
                inbox.conversationOffsets[key] = messages.count
                if inbox.reactionOffsets == nil { inbox.reactionOffsets = [:] }
                inbox.reactionOffsets?[key] = changes.map(\.sequence).max() ?? 0
            }
        }

        deliveries.sort {
            ($0.reactionChange?.createdAt ?? $0.message.createdAt) < ($1.reactionChange?.createdAt ?? $1.message.createdAt)
        }
        // Broker attachment delivery must succeed before advancing the inbox.
        try preparing?(deliveries)
        if consuming && !includingRead { try saveInbox(inbox, for: agentID) }
        return deliveries
    }

    public func participantRoster(for agentID: UUID, conversationID: UUID) throws -> MessengerRoster {
        let agents = try loadAgents()
        guard let readingAgent = agents.first(where: { $0.id == agentID }) else {
            throw WorkspaceError.missingAgent(agentID)
        }
        guard let conversation = try loadConversations().first(where: {
            $0.id == conversationID && $0.participantIDs.contains(agentID)
        }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }

        let agentsByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let messages = try loadMessages(conversationID: conversationID)
        var lastActivity: [UUID: Date] = [:]
        for message in messages {
            guard case .agent(let authorID) = message.author else { continue }
            lastActivity[authorID] = max(lastActivity[authorID] ?? .distantPast, message.createdAt)
        }

        let me = MessengerIdentity(handle: .me, agentID: agentID, displayName: readingAgent.displayName)
        let participants = conversation.participantIDs.compactMap { participantID -> MessengerParticipantStatus? in
            guard let agent = agentsByID[participantID] else { return nil }
            let identity = participantID == agentID
                ? me
                : MessengerIdentity(handle: .bot, agentID: participantID, displayName: agent.displayName)
            return MessengerParticipantStatus(
                participant: identity,
                publicDescription: agent.publicDescription,
                lastActiveAt: lastActivity[participantID]
            )
        }.sorted {
            if $0.participant.handle == .me { return true }
            if $1.participant.handle == .me { return false }
            return $0.participant.displayName.localizedCaseInsensitiveCompare(
                $1.participant.displayName
            ) == .orderedAscending
        }
        return MessengerRoster(me: me, conversation: conversation, participants: participants)
    }

    @discardableResult
    public func setReaction(
        conversationID: UUID, messageID: UUID, author: MessageAuthor,
        emoji: String, present: Bool, now: Date = Date()
    ) throws -> ChatMessage {
        let emoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MessageReaction.isValidEmoji(emoji) else {
            throw WorkspaceError.invalidReaction
        }
        guard let conversation = try loadConversations().first(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        switch author {
        case .user: break
        case .agent(let id):
            guard conversation.participantIDs.contains(id), try loadAgents().contains(where: { $0.id == id }) else {
                throw WorkspaceError.missingAgent(id)
            }
        case .system: throw WorkspaceError.invalidReaction
        }
        return try withConversationLock(conversationID) {
            var messages = try loadMessages(conversationID: conversationID)
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
                throw WorkspaceError.missingMessage(messageID)
            }
            var reactions = messages[index].reactions ?? []
            let existing = reactions.firstIndex { $0.author == author && $0.emoji == emoji }
            guard present != (existing != nil) else { return messages[index] }
            if present {
                reactions.append(MessageReaction(id: UUID(), author: author, emoji: emoji, createdAt: now))
            } else if let existing {
                reactions.remove(at: existing)
            }
            let sequence = (messages.flatMap { $0.reactionChanges ?? [] }.map(\.sequence).max() ?? 0) + 1
            let change = MessageReactionChange(
                id: UUID(), conversationID: conversationID, messageID: messageID,
                sequence: sequence, author: author, emoji: emoji, removed: !present, createdAt: now
            )
            messages[index].reactions = reactions
            messages[index].reactionChanges = (messages[index].reactionChanges ?? []) + [change]
            // Persist the badge and its inbox event in the same atomic write.
            try write(messages, to: conversationDirectory(id: conversationID).appendingPathComponent("messages.json"))
            return messages[index]
        }
    }

    public func sendAgentMessage(
        agentID: UUID,
        conversationID: UUID,
        body: String,
        attachmentIDs: [UUID] = [],
        now: Date = Date()
    ) throws -> ChatMessage {
        let name = try validatedName(body)
        guard try loadAgents().contains(where: { $0.id == agentID }) else {
            throw WorkspaceError.missingAgent(agentID)
        }
        guard let conversation = try loadConversations().first(where: { $0.id == conversationID }),
              conversation.participantIDs.contains(agentID) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let availableAttachmentIDs = Set(try loadAttachments(conversationID: conversationID).map(\.id))
        guard Set(attachmentIDs).count == attachmentIDs.count,
              Set(attachmentIDs).isSubset(of: availableAttachmentIDs) else {
            throw WorkspaceError.invalidAttachment
        }
        let message = ChatMessage(
            conversationID: conversationID,
            author: .agent(agentID),
            body: name,
            createdAt: now,
            delivery: .delivered,
            attachmentIDs: attachmentIDs
        )
        try append(message)
        var updated = conversation
        updated.updatedAt = now
        try updateConversation(updated)
        return message
    }

    public func notificationRecipientIDs(for messages: [ChatMessage]) throws -> Set<UUID> {
        let conversationsByID = Dictionary(
            uniqueKeysWithValues: try loadConversations().map { ($0.id, $0) }
        )
        var recipientIDs = Set<UUID>()

        for message in messages {
            guard case .agent(let senderID) = message.author,
                  let conversation = conversationsByID[message.conversationID],
                  conversation.kind == .group else { continue }

            recipientIDs.formUnion(
                conversation.participantIDs.filter { $0 != senderID }
            )
        }

        return recipientIDs
    }

    public func sendUserMessage(
        conversationID: UUID,
        body: String,
        attachmentIDs: [UUID] = [],
        now: Date = Date()
    ) throws -> ChatMessage {
        let text = try validatedName(body)
        guard var conversation = try loadConversations().first(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let message = ChatMessage(
            conversationID: conversationID,
            author: .user,
            body: text,
            createdAt: now,
            delivery: .delivered,
            attachmentIDs: attachmentIDs
        )
        try append(message)
        conversation.updatedAt = now
        try updateConversation(conversation)
        return message
    }

    /// Queue retries reuse the request UUID, so restarting after delivery never sends twice.
    public func sendSharedMessage(_ request: SharedRequest, files: [URL]) throws -> ChatMessage {
        guard var conversation = try loadConversations().first(where: { $0.id == request.conversationID }),
              request.filenames.count == files.count else { throw SharedInboxError.invalidRequest }
        return try withConversationLock(conversation.id) {
            var messages = try loadMessages(conversationID: conversation.id)
            if let existing = messages.first(where: { $0.id == request.id }) { return existing }
            var imported: [ConversationAttachment] = []
            do {
                for file in files {
                    imported.append(try importAttachment(from: file, into: conversation.id,
                        mediaType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"))
                }
                let message = ChatMessage(id: request.id, conversationID: conversation.id, author: .user,
                    body: request.body.isEmpty ? "Sent \(files.count) attachment\(files.count == 1 ? "" : "s")" : request.body,
                    delivery: .queued, attachmentIDs: imported.map(\.id))
                messages.append(message)
                try write(messages, to: conversationDirectory(id: conversation.id).appendingPathComponent("messages.json"))
                conversation.updatedAt = message.createdAt
                try? updateConversation(conversation)
                return message
            } catch {
                for attachment in imported { try? removeAttachment(attachment) }
                throw error
            }
        }
    }

    public func loadMessages(conversationID: UUID) throws -> [ChatMessage] {
        let file = conversationDirectory(id: conversationID).appendingPathComponent("messages.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try read([ChatMessage].self, from: file)
    }

    private func validatedName(_ rawName: String) throws -> String {
        let value = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw WorkspaceError.emptyName }
        return value
    }
}
