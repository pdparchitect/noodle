import Foundation

extension WorkspaceRepository {
    public func createGroup(
        named rawName: String,
        publicDescription: String? = nil,
        participantIDs: [UUID],
        existingAgents: [AgentRecord],
        now: Date = Date()
    ) throws -> BotConversation {
        let name = try ConversationName.validated(rawName)
        let uniqueIDs = Array(Set(participantIDs))
        guard !uniqueIDs.isEmpty else { throw WorkspaceError.insufficientGroupParticipants }

        let knownIDs = Set(existingAgents.map(\.id))
        guard Set(uniqueIDs).isSubset(of: knownIDs) else {
            throw WorkspaceError.missingAgent(uniqueIDs.first(where: { !knownIDs.contains($0) }) ?? UUID())
        }

        let conversation = BotConversation(
            displayName: name,
            publicDescription: Self.normalizedOptionalText(publicDescription),
            kind: .group,
            participantIDs: uniqueIDs.sorted { $0.uuidString < $1.uuidString },
            createdAt: now,
            updatedAt: now
        )
        try createConversationFiles(conversation)
        return conversation
    }

    public func updateGroupParticipants(
        conversationID: UUID,
        participantIDs: [UUID],
        existingAgents: [AgentRecord],
        now: Date = Date()
    ) throws -> BotConversation {
        guard let conversation = try loadConversations().first(where: {
            $0.id == conversationID && $0.kind == .group
        }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }

        return try updateGroup(
            conversationID: conversationID,
            named: conversation.displayName,
            publicDescription: conversation.publicDescription,
            participantIDs: participantIDs,
            existingAgents: existingAgents,
            now: now
        )
    }

    public func updateGroup(
        conversationID: UUID,
        named rawName: String,
        publicDescription: String?,
        participantIDs: [UUID],
        existingAgents: [AgentRecord],
        now: Date = Date()
    ) throws -> BotConversation {
        guard FileManager.default.fileExists(atPath: conversationDirectory(id: conversationID).path) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        return try withConversationLock(conversationID) {
            guard var conversation = try loadConversations().first(where: {
                $0.id == conversationID && $0.kind == .group
            }) else {
                throw WorkspaceError.missingConversation(conversationID)
            }

            let name = try ConversationName.validated(rawName)
            let uniqueIDs = Array(Set(participantIDs))
            guard !uniqueIDs.isEmpty else { throw WorkspaceError.insufficientGroupParticipants }

            let knownIDs = Set(existingAgents.map(\.id))
            guard Set(uniqueIDs).isSubset(of: knownIDs) else {
                throw WorkspaceError.missingAgent(uniqueIDs.first(where: { !knownIDs.contains($0) }) ?? UUID())
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var inboxWrites: [(URL, Data)] = []
            let previousIDs = Set(conversation.participantIDs)
            let addedIDs = Set(uniqueIDs).subtracting(previousIDs)
            let removedIDs = previousIDs.subtracting(uniqueIDs)
            let normalizedDescription = Self.normalizedOptionalText(publicDescription)
            let descriptionChanged = conversation.publicDescription != normalizedDescription
            let needsNotice = !addedIDs.isEmpty || !removedIDs.isEmpty || descriptionChanged
            var messages = needsNotice ? try loadMessages(conversationID: conversation.id) : []
            if !addedIDs.isEmpty {
                let messageCount = messages.count
                let reactionSequence = messages.flatMap { $0.reactionChanges ?? [] }.map(\.sequence).max() ?? 0
                let conversationKey = conversation.id.uuidString.lowercased()
                for agentID in addedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                    var inbox = try loadInbox(for: agentID)
                    inbox.conversationOffsets[conversationKey] = messageCount
                    if inbox.reactionOffsets == nil { inbox.reactionOffsets = [:] }
                    inbox.reactionOffsets?[conversationKey] = reactionSequence
                    let file = inboxURL(for: agentID)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    inboxWrites.append((file, try encoder.encode(inbox)))
                }
            }

            conversation.displayName = name
            conversation.publicDescription = normalizedDescription
            conversation.participantIDs = uniqueIDs.sorted { $0.uuidString < $1.uuidString }
            conversation.updatedAt = now
            if needsNotice {
                let namesByID = Dictionary(uniqueKeysWithValues: existingAgents.map { ($0.id, $0.displayName) })
                let addedNames = addedIDs.compactMap { namesByID[$0] }.sorted()
                let removedNames = removedIDs.compactMap { namesByID[$0] }.sorted()
                var changes: [GroupNotice] = []
                if !addedNames.isEmpty {
                    changes.append(.membersAdded(addedNames))
                }
                if !removedNames.isEmpty {
                    changes.append(.membersRemoved(removedNames))
                }
                if descriptionChanged {
                    changes.append(.descriptionChanged(normalizedDescription))
                }
                messages.append(ChatMessage(
                    conversationID: conversation.id,
                    author: .system,
                    body: changes.map(\.body).joined(separator: " "),
                    createdAt: now,
                    delivery: .delivered
                ))
            }
            let directory = conversationDirectory(id: conversation.id)
            var writes = [(directory.appendingPathComponent("conversation.json"), try encoder.encode(conversation))]
            writes.append(contentsOf: inboxWrites)
            if needsNotice { writes.append((directory.appendingPathComponent("messages.json"), try encoder.encode(messages))) }
            // Prepare every destination before publishing anything, then undo only
            // completed writes if a later atomic replacement fails. The conversation
            // lock also protects the notice from racing transcript appends.
            let previous = try writes.map { file, _ in
                FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            }
            var completed = 0
            do {
                for (file, data) in writes {
                    try AtomicFile.write(data, to: file)
                    completed += 1
                }
            } catch {
                let saveError = error
                var restoreError: Error?
                for index in (0..<completed).reversed() {
                    do {
                        if let data = previous[index] { try AtomicFile.write(data, to: writes[index].0) }
                        else { try FileManager.default.removeItem(at: writes[index].0) }
                    } catch { if restoreError == nil { restoreError = error } }
                }
                if let restoreError {
                    throw NSError(domain: "Noodle.GroupEdit", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "\(saveError.localizedDescription) Previous group settings could not be fully restored: \(restoreError.localizedDescription)"])
                }
                throw saveError
            }
            return conversation
        }
    }

    public func updateConversation(_ conversation: BotConversation) throws {
        let file = conversationDirectory(id: conversation.id).appendingPathComponent("conversation.json")
        try write(conversation, to: file)
    }

    public func deleteConversation(id: UUID) throws {
        let directory = conversationDirectory(id: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkspaceError.missingConversation(id)
        }
        try FileManager.default.removeItem(at: directory)
    }

    public func loadConversations() throws -> [BotConversation] {
        try prepare()
        return try loadChildren(from: conversationsURL, filename: "conversation.json", as: BotConversation.self)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func createConversationFiles(_ conversation: BotConversation) throws {
        try prepare()
        let directory = conversationDirectory(id: conversation.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try write(conversation, to: directory.appendingPathComponent("conversation.json"))
        try write([ChatMessage](), to: directory.appendingPathComponent("messages.json"))
        try FileManager.default.createDirectory(
            at: attachmentsDirectory(conversationID: conversation.id),
            withIntermediateDirectories: true
        )
    }
}
