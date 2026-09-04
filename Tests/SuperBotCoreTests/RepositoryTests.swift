import XCTest
@testable import SuperBotCore

final class RepositoryTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private var launcher: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superbot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        launcher = root.appendingPathComponent("SuperBot")
        XCTAssertTrue(FileManager.default.createFile(atPath: launcher.path, contents: Data("binary".utf8)))
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: launcher)
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testAgentWorkspaceUsesStableOpaqueIdentifier() throws {
        let created = try repository.createAgent(named: "Build Bot")
        let directory = repository.directory(for: created.agent)

        XCTAssertEqual(directory.lastPathComponent, created.agent.id.uuidString.lowercased())
        XCTAssertFalse(directory.lastPathComponent.contains("build"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("agent.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("instructions.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("memory.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("AGENTS.md").path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: directory.appendingPathComponent("CLAUDE.md").path
            ),
            "AGENTS.md"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: directory.appendingPathComponent(".agents/skills/messenger/messenger").path
            ),
            launcher.path
        )
        let agentsGuide = try String(
            contentsOf: directory.appendingPathComponent("AGENTS.md"),
            encoding: .utf8
        )
        let messengerGuide = try String(
            contentsOf: directory.appendingPathComponent(".agents/skills/messenger/SKILL.md"),
            encoding: .utf8
        )
        XCTAssertTrue(agentsGuide.contains("text(deliveries)"))
        XCTAssertTrue(agentsGuide.contains("named `participants`"))
        XCTAssertTrue(agentsGuide.contains("never inspect `result.content`"))
        XCTAssertTrue(messengerGuide.contains("text(deliveries)"))
        XCTAssertTrue(messengerGuide.contains("named participant roster"))
        XCTAssertTrue(messengerGuide.contains("never inspect `result.content`"))
        XCTAssertEqual(created.conversation.participantIDs, [created.agent.id])
    }

    func testRenameDoesNotMoveWorkspace() throws {
        let created = try repository.createAgent(
            named: "Research Bot",
            harnessIdentifier: "codex",
            modelIdentifier: "gpt-test",
            reasoningEffort: "high"
        )
        let originalDirectory = repository.directory(for: created.agent)
        let renamed = try repository.updateAgent(
            created.agent,
            displayName: "Evidence Bot",
            harnessIdentifier: "codex",
            modelIdentifier: "gpt-test-2",
            reasoningEffort: "medium"
        )

        XCTAssertEqual(renamed.id, created.agent.id)
        XCTAssertEqual(repository.directory(for: renamed), originalDirectory)
        XCTAssertEqual(try repository.loadAgents().first?.displayName, "Evidence Bot")
        XCTAssertEqual(try repository.loadAgents().first?.harnessIdentifier, "codex")
        XCTAssertEqual(try repository.loadAgents().first?.modelIdentifier, "gpt-test-2")
        XCTAssertEqual(try repository.loadAgents().first?.reasoningEffort, "medium")
    }

    func testAvatarPreferencesAndPreparedPhotoPersistAcrossRename() throws {
        let created = try repository.createAgent(named: "Design Bot")
        let photo = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let customized = try repository.updateAgent(
            created.agent,
            displayName: created.agent.displayName,
            harnessIdentifier: created.agent.harnessIdentifier,
            modelIdentifier: created.agent.modelIdentifier,
            reasoningEffort: created.agent.reasoningEffort,
            avatarSymbolName: "paintbrush.fill",
            avatarColorIndex: 4,
            avatarImageData: photo
        )

        let loaded = try XCTUnwrap(try repository.loadAgents().first)
        XCTAssertEqual(loaded.avatarSymbolName, "paintbrush.fill")
        XCTAssertEqual(loaded.avatarColorIndex, 4)
        XCTAssertEqual(loaded.avatarImageData, photo)

        let renamed = try repository.renameAgent(customized, to: "Creative Bot")
        XCTAssertEqual(renamed.avatarSymbolName, "paintbrush.fill")
        XCTAssertEqual(renamed.avatarColorIndex, 4)
        XCTAssertEqual(renamed.avatarImageData, photo)
    }

    func testGroupAndTranscriptRoundTrip() throws {
        let first = try repository.createAgent(named: "Research Bot")
        let second = try repository.createAgent(named: "Build Bot")
        let agents = [first.agent, second.agent]
        let group = try repository.createGroup(
            named: "Launch Room",
            participantIDs: agents.map(\.id),
            existingAgents: agents
        )
        let message = ChatMessage(
            conversationID: group.id,
            author: .user,
            body: "Prepare the launch checklist.",
            delivery: .queued
        )
        try repository.append(message)

        let loadedGroup = try XCTUnwrap(
            repository.loadConversations().first(where: { $0.id == group.id })
        )
        XCTAssertEqual(loadedGroup.id, group.id)
        XCTAssertEqual(loadedGroup.displayName, "Launch Room")
        XCTAssertEqual(loadedGroup.participantIDs, group.participantIDs)

        let loadedMessage = try XCTUnwrap(
            repository.loadMessages(conversationID: group.id).first
        )
        XCTAssertEqual(loadedMessage.id, message.id)
        XCTAssertEqual(loadedMessage.body, message.body)
        XCTAssertEqual(loadedMessage.delivery, .queued)
    }

    func testUpdateGroupMembershipPreservesHistoryAndStartsNewMemberAtCurrentEnd() throws {
        let first = try repository.createAgent(named: "Research Bot")
        let second = try repository.createAgent(named: "Build Bot")
        let third = try repository.createAgent(named: "Review Bot")
        let agents = [first.agent, second.agent, third.agent]
        let group = try repository.createGroup(
            named: "Launch Room",
            participantIDs: [first.agent.id, second.agent.id],
            existingAgents: agents
        )
        let historical = ChatMessage(
            conversationID: group.id,
            author: .user,
            body: "Earlier context",
            delivery: .delivered
        )
        try repository.append(historical)

        let updated = try repository.updateGroupParticipants(
            conversationID: group.id,
            participantIDs: [second.agent.id, third.agent.id],
            existingAgents: agents
        )

        XCTAssertEqual(Set(updated.participantIDs), [second.agent.id, third.agent.id])
        let preservedHistory = try repository.loadMessages(conversationID: group.id)
        XCTAssertEqual(preservedHistory.map(\.id), [historical.id])
        XCTAssertEqual(preservedHistory.map(\.body), ["Earlier context"])
        XCTAssertTrue(try repository.latestMessages(for: first.agent.id).isEmpty)
        XCTAssertTrue(try repository.latestMessages(for: third.agent.id).isEmpty)

        let fresh = ChatMessage(
            conversationID: group.id,
            author: .user,
            body: "New context",
            delivery: .delivered
        )
        try repository.append(fresh)

        XCTAssertEqual(
            try repository.latestMessages(for: third.agent.id).map(\.message.body),
            ["New context"]
        )
    }

    func testUpdateGroupMembershipRequiresTwoKnownBots() throws {
        let first = try repository.createAgent(named: "Research Bot")
        let second = try repository.createAgent(named: "Build Bot")
        let agents = [first.agent, second.agent]
        let group = try repository.createGroup(
            named: "Launch Room",
            participantIDs: [first.agent.id, second.agent.id],
            existingAgents: agents
        )

        XCTAssertThrowsError(
            try repository.updateGroupParticipants(
                conversationID: group.id,
                participantIDs: [first.agent.id],
                existingAgents: agents
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceError, .insufficientGroupParticipants)
        }

        XCTAssertThrowsError(
            try repository.updateGroupParticipants(
                conversationID: group.id,
                participantIDs: [first.agent.id, UUID()],
                existingAgents: agents
            )
        ) { error in
            guard case .missingAgent = error as? WorkspaceError else {
                return XCTFail("Expected a missing agent error")
            }
        }
    }

    func testDeleteGroupRemovesTranscriptAndAttachmentsWithoutDeletingBots() throws {
        let first = try repository.createAgent(named: "Research Bot")
        let second = try repository.createAgent(named: "Build Bot")
        let group = try repository.createGroup(
            named: "Launch Room",
            participantIDs: [first.agent.id, second.agent.id],
            existingAgents: [first.agent, second.agent]
        )
        let source = root.appendingPathComponent("brief.txt")
        try Data("ship it".utf8).write(to: source)
        _ = try repository.importAttachment(from: source, into: group.id, mediaType: "text/plain")

        try repository.deleteConversation(id: group.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.conversationDirectory(id: group.id).path))
        XCTAssertEqual(try repository.loadAgents().count, 2)
        XCTAssertFalse(try repository.loadConversations().contains(where: { $0.id == group.id }))
    }

    func testDeleteAgentRemovesWorkspaceAndDirectChatAndLeavesGroups() throws {
        let first = try repository.createAgent(named: "Research Bot")
        let second = try repository.createAgent(named: "Build Bot")
        let group = try repository.createGroup(
            named: "Launch Room",
            participantIDs: [first.agent.id, second.agent.id],
            existingAgents: [first.agent, second.agent]
        )

        try repository.deleteAgent(first.agent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: first.agent).path))
        XCTAssertFalse(try repository.loadConversations().contains(where: { $0.id == first.conversation.id }))
        XCTAssertEqual(try repository.loadAgents().map(\.id), [second.agent.id])
        let survivingGroup = try XCTUnwrap(try repository.loadConversations().first(where: { $0.id == group.id }))
        XCTAssertEqual(survivingGroup.participantIDs, [second.agent.id])
    }

    func testAttachmentIsOwnedByConversation() throws {
        let created = try repository.createAgent(named: "Media Bot")
        let source = root.appendingPathComponent("brief.txt")
        try Data("ship it".utf8).write(to: source)

        let attachment = try repository.importAttachment(
            from: source,
            into: created.conversation.id,
            mediaType: "text/plain"
        )
        let loaded = try XCTUnwrap(repository.loadAttachments(conversationID: created.conversation.id).first)

        XCTAssertEqual(loaded.id, attachment.id)
        XCTAssertEqual(loaded.conversationID, attachment.conversationID)
        XCTAssertEqual(loaded.storedFilename, attachment.storedFilename)
        XCTAssertEqual(loaded.originalFilename, "brief.txt")
        XCTAssertEqual(
            try String(contentsOf: repository.attachmentFileURL(loaded), encoding: .utf8),
            "ship it"
        )
        XCTAssertTrue(repository.attachmentFileURL(loaded).path.hasPrefix(
            repository.conversationDirectory(id: created.conversation.id).path
        ))
    }

    func testMessengerDeliveryIncludesAbsoluteAttachmentPath() throws {
        let created = try repository.createAgent(named: "Vision Bot")
        let source = root.appendingPathComponent("reference.png")
        try Data("image bytes".utf8).write(to: source)
        let attachment = try repository.importAttachment(
            from: source,
            into: created.conversation.id,
            mediaType: "image/png"
        )
        try repository.append(ChatMessage(
            conversationID: created.conversation.id,
            author: .user,
            body: "What is in this image?",
            delivery: .delivered,
            attachmentIDs: [attachment.id]
        ))

        let command = repository.directory(for: created.agent)
            .appendingPathComponent(".agents/skills/messenger/messenger")
        let result = MessengerCLI.run(arguments: [command.path, "--get-latest", "--peek"])
        XCTAssertEqual(result.exitCode, 0)
        let delivery = try XCTUnwrap(
            decode([MessengerDelivery].self, from: result.standardOutput).first
        )
        let deliveredAttachment = try XCTUnwrap(delivery.attachments.first)
        let expectedURL = repository.attachmentFileURL(attachment).standardizedFileURL

        XCTAssertEqual(deliveredAttachment.absolutePath, expectedURL.path)
        XCTAssertEqual(deliveredAttachment.originalFilename, "reference.png")
        XCTAssertTrue(deliveredAttachment.absolutePath.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: deliveredAttachment.absolutePath))
    }

    func testMessengerConsumesUnreadMessagesAndCanReply() throws {
        let created = try repository.createAgent(named: "Messenger Bot")
        let command = repository.directory(for: created.agent)
            .appendingPathComponent(".agents/skills/messenger/messenger")
        let incoming = ChatMessage(
            conversationID: created.conversation.id,
            author: .user,
            body: "What changed?",
            delivery: .queued
        )
        try repository.append(incoming)

        let first = MessengerCLI.run(arguments: [command.path, "--get-latest"])
        XCTAssertEqual(first.exitCode, 0)
        let deliveries = try decode([MessengerDelivery].self, from: first.standardOutput)
        XCTAssertEqual(deliveries.map(\.message.body), ["What changed?"])

        let second = MessengerCLI.run(arguments: [command.path, "--get-latest"])
        XCTAssertEqual(try decode([MessengerDelivery].self, from: second.standardOutput).count, 0)

        let reply = MessengerCLI.run(arguments: [
            command.path,
            "--send",
            "--conversation", created.conversation.id.uuidString,
            "--body", "The workspace bridge is ready."
        ])
        XCTAssertEqual(reply.exitCode, 0)
        let sent = try decode(ChatMessage.self, from: reply.standardOutput)
        XCTAssertEqual(sent.author, .agent(created.agent.id))
        XCTAssertEqual(sent.delivery, .delivered)
    }

    func testMessengerDeliveryIdentifiesMeParticipantsAndEachSender() throws {
        let buildBot = try repository.createAgent(named: "Build Bot")
        let bob = try repository.createAgent(named: "Bob")
        let group = try repository.createGroup(
            named: "The war room",
            participantIDs: [buildBot.agent.id, bob.agent.id],
            existingAgents: [buildBot.agent, bob.agent]
        )
        try repository.append(ChatMessage(
            conversationID: group.id,
            author: .user,
            body: "Who is here?",
            delivery: .delivered
        ))
        _ = try repository.sendAgentMessage(
            agentID: bob.agent.id,
            conversationID: group.id,
            body: "Bob is here."
        )

        let deliveries = try repository.latestMessages(for: buildBot.agent.id, consuming: false)
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(
            deliveries.first?.me,
            MessengerIdentity(handle: .me, agentID: buildBot.agent.id, displayName: "Build Bot")
        )

        let participants = try XCTUnwrap(deliveries.first?.participants)
        XCTAssertTrue(participants.contains(
            MessengerIdentity(handle: .me, agentID: buildBot.agent.id, displayName: "Build Bot")
        ))
        XCTAssertTrue(participants.contains(
            MessengerIdentity(handle: .bot, agentID: bob.agent.id, displayName: "Bob")
        ))
        XCTAssertEqual(
            deliveries.map(\.sender),
            [
                MessengerIdentity(handle: .user, displayName: "User"),
                MessengerIdentity(handle: .bot, agentID: bob.agent.id, displayName: "Bob")
            ]
        )
    }

    func testMessengerCanUseRuntimeWorkspaceEnvironment() throws {
        let created = try repository.createAgent(named: "Environment Bot")
        let incoming = ChatMessage(
            conversationID: created.conversation.id,
            author: .user,
            body: "Wake up",
            delivery: .queued
        )
        try repository.append(incoming)

        let result = MessengerCLI.run(
            arguments: ["messenger", "--get-latest"],
            environment: ["SUPERBOT_WORKSPACE": repository.directory(for: created.agent).path]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try decode([MessengerDelivery].self, from: result.standardOutput).count, 1)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from string: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(string.utf8))
    }
}
