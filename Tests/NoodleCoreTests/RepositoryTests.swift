import AppKit
import XCTest
import UniformTypeIdentifiers
@testable import NoodleCore

final class RepositoryTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private var launcher: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        launcher = root.appendingPathComponent("Noodle")
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("instructions.md").path))
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
        XCTAssertTrue(agentsGuide.contains(MessengerDocumentation.bootstrapInstructions))
        XCTAssertTrue(agentsGuide.contains("## Backstory"))
        XCTAssertTrue(agentsGuide.contains("<!-- noodle:managed:start -->"))
        XCTAssertFalse(agentsGuide.contains(MessengerDocumentation.transportInstructions))
        XCTAssertFalse(agentsGuide.contains("TextEncoder"))
        XCTAssertFalse(agentsGuide.contains("noodle_get_latest"))
        XCTAssertTrue(messengerGuide.contains("tools.exec_command"))
        XCTAssertTrue(messengerGuide.contains("--get-latest --inline-images"))
        XCTAssertTrue(messengerGuide.contains("max_output_tokens: 250000"))
        XCTAssertTrue(messengerGuide.contains("image(visual.dataURL"))
        XCTAssertTrue(messengerGuide.contains("named `participants`"))
        XCTAssertTrue(messengerGuide.contains("--body-percent-encoded"))
        XCTAssertTrue(messengerGuide.contains("--attach <file-path-or-url>"))
        XCTAssertTrue(messengerGuide.contains("--list-participants"))
        XCTAssertTrue(messengerGuide.contains("private backstory"))
        XCTAssertTrue(messengerGuide.contains("named participant roster"))
        XCTAssertFalse(messengerGuide.contains("noodle_get_latest"))
        XCTAssertEqual(created.conversation.participantIDs, [created.agent.id])
    }

    func testClaudeSkillDiscoveryLinkIsCreatedAndRepairedOnBootstrap() throws {
        let bot = try repository.createAgent(named: "Claude Bot")
        let directory = repository.directory(for: bot.agent)
        let link = directory.appendingPathComponent(".claude/skills")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "../.agents/skills")
        let shared = directory.appendingPathComponent(".agents/skills/custom/SKILL.md")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Custom skill".write(to: shared, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: link.appendingPathComponent("custom/SKILL.md"), encoding: .utf8), "Custom skill")
        try FileManager.default.removeItem(at: link)
        // This is the bulk bootstrap called by NoodleStore.reload at app startup.
        try repository.synchronizeAgentWorkspaces([bot.agent])
        try repository.synchronizeAgentWorkspaces([bot.agent])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "../.agents/skills")
        XCTAssertEqual(
            try String(contentsOf: link.appendingPathComponent("messenger/SKILL.md"), encoding: .utf8),
            try String(contentsOf: directory.appendingPathComponent(".agents/skills/messenger/SKILL.md"), encoding: .utf8)
        )
    }

    func testClaudeNativeSkillsAndSettingsSurviveBootstrap() throws {
        let bot = try repository.createAgent(named: "Native Skills Bot")
        let directory = repository.directory(for: bot.agent)
        let skills = directory.appendingPathComponent(".claude/skills")
        try FileManager.default.removeItem(at: skills)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let settings = directory.appendingPathComponent(".claude/settings.json")
        try "{}".write(to: settings, atomically: true, encoding: .utf8)
        let custom = skills.appendingPathComponent("custom/SKILL.md")
        try FileManager.default.createDirectory(at: custom.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Native skill".write(to: custom, atomically: true, encoding: .utf8)
        let sharedCustom = directory.appendingPathComponent(".agents/skills/custom/SKILL.md")
        try FileManager.default.createDirectory(at: sharedCustom.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Shared skill".write(to: sharedCustom, atomically: true, encoding: .utf8)
        try repository.synchronizeAgentWorkspace(bot.agent)
        try repository.synchronizeAgentWorkspace(bot.agent)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{}")
        XCTAssertEqual(try String(contentsOf: custom, encoding: .utf8), "Native skill")
        XCTAssertEqual(try String(contentsOf: sharedCustom, encoding: .utf8), "Shared skill")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: skills.appendingPathComponent("messenger").path),
            "../../.agents/skills/messenger"
        )
    }

    func testClaudeRedirectedDirectoriesAreNotModified() throws {
        let bot = try repository.createAgent(named: "Redirected Bot")
        let directory = repository.directory(for: bot.agent)
        let claude = directory.appendingPathComponent(".claude")
        let external = root.appendingPathComponent("external-claude")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: claude)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: external)
        try repository.synchronizeAgentWorkspace(bot.agent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: claude.path), external.path)
        try FileManager.default.removeItem(at: claude)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let skills = claude.appendingPathComponent("skills")
        try FileManager.default.createSymbolicLink(at: skills, withDestinationURL: external)
        try repository.synchronizeAgentWorkspace(bot.agent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: skills.path), external.path)
    }

    func testBackstoryIsStoredInAgentsFileAndSurvivesSynchronization() throws {
        let created = try repository.createAgent(named: "Story Bot")
        let directory = repository.directory(for: created.agent)
        let agentsFile = directory.appendingPathComponent("AGENTS.md")

        try repository.updateAgentBackstory(
            created.agent,
            backstory: "You are a pragmatic release engineer. Keep answers short and decisive."
        )
        try repository.synchronizeAgentWorkspace(created.agent)

        XCTAssertEqual(
            try repository.loadAgentBackstory(created.agent),
            "You are a pragmatic release engineer. Keep answers short and decisive."
        )
        let contents = try String(contentsOf: agentsFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("You are a pragmatic release engineer"))
        XCTAssertTrue(contents.contains("## Noodle Runtime"))
        XCTAssertTrue(contents.contains(MessengerDocumentation.bootstrapInstructions))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("instructions.md").path
        ))
    }

    func testLegacyInstructionsMigrateIntoAgentsFile() throws {
        let created = try repository.createAgent(named: "Legacy Bot")
        let directory = repository.directory(for: created.agent)
        let agentsFile = directory.appendingPathComponent("AGENTS.md")
        let legacyFile = directory.appendingPathComponent("instructions.md")
        try FileManager.default.removeItem(at: agentsFile)
        try "# Instructions\n\nYou are a careful research librarian.\n".write(
            to: legacyFile,
            atomically: true,
            encoding: .utf8
        )

        try repository.synchronizeAgentWorkspace(created.agent)

        XCTAssertEqual(
            try repository.loadAgentBackstory(created.agent),
            "You are a careful research librarian."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertTrue(
            try String(contentsOf: agentsFile, encoding: .utf8)
                .contains("You are a careful research librarian.")
        )
    }

    func testExistingCustomAgentsFileMigratesAsBackstory() throws {
        let created = try repository.createAgent(named: "Custom Bot")
        let directory = repository.directory(for: created.agent)
        let agentsFile = directory.appendingPathComponent("AGENTS.md")
        try "You are an experienced product designer.\nPrefer direct, visual explanations.\n".write(
            to: agentsFile,
            atomically: true,
            encoding: .utf8
        )

        try repository.synchronizeAgentWorkspace(created.agent)

        XCTAssertEqual(
            try repository.loadAgentBackstory(created.agent),
            "You are an experienced product designer.\nPrefer direct, visual explanations."
        )
        let contents = try String(contentsOf: agentsFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("## Backstory"))
        XCTAssertTrue(contents.contains("## Noodle Runtime"))
    }

    func testRenameDoesNotMoveWorkspace() throws {
        let created = try repository.createAgent(
            named: "Research Bot",
            harnessIdentifier: "codex",
            modelIdentifier: "gpt-test",
            reasoningEffort: "high",
            publicDescription: "Finds and verifies evidence."
        )
        let originalDirectory = repository.directory(for: created.agent)
        let renamed = try repository.updateAgent(
            created.agent,
            displayName: "Evidence Bot",
            harnessIdentifier: "codex",
            modelIdentifier: "gpt-test-2",
            reasoningEffort: "medium",
            publicDescription: created.agent.publicDescription
        )

        XCTAssertEqual(renamed.id, created.agent.id)
        XCTAssertEqual(repository.directory(for: renamed), originalDirectory)
        XCTAssertEqual(try repository.loadAgents().first?.displayName, "Evidence Bot")
        XCTAssertEqual(try repository.loadAgents().first?.harnessIdentifier, "codex")
        XCTAssertEqual(try repository.loadAgents().first?.modelIdentifier, "gpt-test-2")
        XCTAssertEqual(try repository.loadAgents().first?.reasoningEffort, "medium")
        XCTAssertEqual(try repository.loadAgents().first?.publicDescription, "Finds and verifies evidence.")
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

    func testAvatarPreferencesPersistWhenAgentIsCreated() throws {
        let photo = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let created = try repository.createAgent(
            named: "Design Bot",
            avatarSymbolName: "paintbrush.fill",
            avatarColorIndex: 4,
            avatarImageData: photo
        )

        XCTAssertEqual(created.agent.avatarSymbolName, "paintbrush.fill")
        XCTAssertEqual(created.agent.avatarColorIndex, 4)
        XCTAssertEqual(created.agent.avatarImageData, photo)

        let loaded = try XCTUnwrap(try repository.loadAgents().first)
        XCTAssertEqual(loaded.avatarSymbolName, "paintbrush.fill")
        XCTAssertEqual(loaded.avatarColorIndex, 4)
        XCTAssertEqual(loaded.avatarImageData, photo)
    }

    func testUnreadConversationIDsPersistAndCanBeCleared() throws {
        let first = try repository.createAgent(named: "Build Bot")
        let second = try repository.createAgent(named: "Review Bot")
        let unread = Set([first.conversation.id, second.conversation.id])

        try repository.saveUnreadConversationIDs(unread)
        XCTAssertEqual(try repository.loadUnreadConversationIDs(), unread)

        try repository.saveUnreadConversationIDs([second.conversation.id])
        XCTAssertEqual(
            try repository.loadUnreadConversationIDs(),
            [second.conversation.id]
        )

        try repository.saveUnreadConversationIDs([])
        XCTAssertTrue(try repository.loadUnreadConversationIDs().isEmpty)
    }

    func testGroupAndTranscriptRoundTrip() throws {
        let first = try repository.createAgent(named: "Research Bot")
        let second = try repository.createAgent(named: "Build Bot")
        let agents = [first.agent, second.agent]
        let group = try repository.createGroup(
            named: "Launch Room",
            publicDescription: "Coordinate research and implementation for the launch.",
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
        XCTAssertEqual(
            loadedGroup.publicDescription,
            "Coordinate research and implementation for the launch."
        )
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
        XCTAssertEqual(preservedHistory.first?.id, historical.id)
        XCTAssertEqual(preservedHistory.last?.author, .system)
        XCTAssertEqual(
            preservedHistory.last?.body,
            "Review Bot was added to the group. Research Bot was removed from the group."
        )
        XCTAssertTrue(try repository.latestMessages(for: first.agent.id).isEmpty)
        XCTAssertEqual(
            try repository.latestMessages(for: third.agent.id).map(\.message.body),
            ["Review Bot was added to the group. Research Bot was removed from the group."]
        )

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

    func testRenameGroupPreservesIdentityMembersAndHistory() throws {
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
            body: "Keep this history.",
            delivery: .delivered
        )
        try repository.append(message)

        let renamed = try repository.updateGroup(
            conversationID: group.id,
            named: "Release Room",
            publicDescription: group.publicDescription,
            participantIDs: group.participantIDs,
            existingAgents: agents
        )

        XCTAssertEqual(renamed.id, group.id)
        XCTAssertEqual(renamed.displayName, "Release Room")
        XCTAssertEqual(renamed.participantIDs, group.participantIDs)
        XCTAssertEqual(try repository.loadMessages(conversationID: group.id).map(\.id), [message.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.conversationDirectory(id: group.id).path))
    }

    func testUpdateGroupMembershipRequiresAtLeastOneKnownBot() throws {
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
                participantIDs: [],
                existingAgents: agents
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceError, .insufficientGroupParticipants)
        }

        let singleMember = try repository.updateGroupParticipants(
            conversationID: group.id, participantIDs: [first.agent.id], existingAgents: agents
        )
        XCTAssertEqual(singleMember.participantIDs, [first.agent.id])
        XCTAssertEqual(singleMember.kind, .group)

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

    func testSingleBotGroupSupportsMessagingAndRejectsEmptyMembership() throws {
        let bot = try repository.createAgent(named: "Solo")
        let group = try repository.createGroup(named: "Solo workspace", participantIDs: [bot.agent.id, bot.agent.id], existingAgents: [bot.agent])
        XCTAssertEqual(group.kind, .group)
        XCTAssertEqual(group.participantIDs, [bot.agent.id])
        let message = try repository.sendUserMessage(conversationID: group.id, body: "Start here")
        let peek = try repository.latestMessages(for: bot.agent.id, consuming: false)
        XCTAssertEqual(peek.map(\.message.id), [message.id])
        XCTAssertEqual(try repository.latestMessages(for: bot.agent.id).map(\.message.id), [message.id])
        XCTAssertTrue(try repository.latestMessages(for: bot.agent.id, consuming: false).isEmpty)
        XCTAssertThrowsError(try repository.createGroup(named: "Empty", participantIDs: [], existingAgents: [bot.agent])) {
            XCTAssertEqual($0 as? WorkspaceError, .insufficientGroupParticipants)
        }
        XCTAssertThrowsError(try repository.createGroup(named: "Unknown", participantIDs: [UUID()], existingAgents: [bot.agent]))
    }

    func testInboxMigrationPreservesMessageAndReactionCursorsWithoutWritingSkills() throws {
        let bot = try repository.createAgent(named: "Migrating bot")
        let group = try repository.createGroup(named: "Solo", participantIDs: [bot.agent.id], existingAgents: [bot.agent])
        let old = try repository.sendUserMessage(conversationID: group.id, body: "Already read")
        try repository.setReaction(conversationID: group.id, messageID: old.id, author: .user, emoji: "👍", present: true)
        _ = try repository.latestMessages(for: bot.agent.id)
        let directory = repository.directory(for: bot.agent)
        let current = directory.appendingPathComponent(".noodle/inbox.json")
        let legacy = directory.appendingPathComponent(".agents/inbox.json")
        try FileManager.default.moveItem(at: current, to: legacy)
        let legacyBytes = try Data(contentsOf: legacy)
        let fresh = try repository.sendUserMessage(conversationID: group.id, body: "Unread")
        let peek = try repository.latestMessages(for: bot.agent.id, consuming: false)
        XCTAssertEqual(peek.map(\.message.id), [fresh.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertEqual(try repository.latestMessages(for: bot.agent.id).map(\.message.id), [fresh.id])
        XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        // New state takes precedence over the retained legacy snapshot.
        XCTAssertTrue(try repository.latestMessages(for: bot.agent.id).isEmpty)
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

    func testAttachmentDataIsCopiedIntoConversationStorage() throws {
        let created = try repository.createAgent(named: "Clipboard Bot")
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])

        let attachment = try repository.importAttachment(
            data: imageData,
            originalFilename: "../Pasted Image.png",
            into: created.conversation.id,
            mediaType: "image/png"
        )

        XCTAssertEqual(attachment.originalFilename, "Pasted Image.png")
        XCTAssertEqual(attachment.mediaType, "image/png")
        XCTAssertEqual(attachment.byteCount, Int64(imageData.count))
        XCTAssertEqual(try Data(contentsOf: repository.attachmentFileURL(attachment)), imageData)
    }

    func testImageContentRepairsIncorrectAttachmentMediaType() throws {
        let created = try repository.createAgent(named: "Image Bot")
        let source = root.appendingPathComponent("mislabeled.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let jpegData = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        try jpegData.write(to: source)

        let imported = try repository.importAttachment(
            from: source,
            into: created.conversation.id,
            mediaType: "application/octet-stream"
        )
        XCTAssertEqual(imported.mediaType, "image/jpeg")

        let stale = ConversationAttachment(
            id: imported.id,
            conversationID: imported.conversationID,
            originalFilename: imported.originalFilename,
            storedFilename: imported.storedFilename,
            mediaType: "application/octet-stream",
            byteCount: imported.byteCount,
            createdAt: imported.createdAt
        )
        let metadataURL = repository.attachmentFileURL(imported)
            .deletingLastPathComponent()
            .appendingPathComponent("\(imported.id.uuidString.lowercased()).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stale).write(to: metadataURL, options: .atomic)

        let repaired = try XCTUnwrap(
            repository.loadAttachments(conversationID: created.conversation.id).first
        )
        XCTAssertEqual(repaired.mediaType, "image/jpeg")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(ConversationAttachment.self, from: Data(contentsOf: metadataURL))
        XCTAssertEqual(persisted.mediaType, "image/jpeg")
    }

    func testAttachmentTransferLoadsPastedImageData() async throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let provider = NSItemProvider()
        provider.suggestedName = "Clipboard Screenshot"
        provider.registerDataRepresentation(for: .png, visibility: .all) { completion in
            completion(imageData, nil)
            return nil
        }

        let payload = try await AttachmentTransfer.load(provider)
        guard case .data(let loadedData, let filename, let mediaType) = payload else {
            return XCTFail("Expected an in-memory attachment")
        }

        XCTAssertEqual(loadedData, imageData)
        XCTAssertEqual(filename, "Clipboard Screenshot.png")
        XCTAssertEqual(mediaType, "image/png")
    }

    func testAttachmentTransferLoadsCopiedFileURL() async throws {
        let source = root.appendingPathComponent("copied-report.pdf")
        try Data("PDF".utf8).write(to: source)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))

        let payload = try await AttachmentTransfer.load(provider)
        guard case .file(let loadedURL) = payload else {
            return XCTFail("Expected a copied file URL")
        }

        XCTAssertEqual(loadedURL, source.standardizedFileURL)
    }

    func testSendUserMessagePersistsCommandAndUpdatesConversation() throws {
        let created = try repository.createAgent(named: "Build Bot")
        let sentAt = Date(timeIntervalSince1970: 1_780_000_000)

        let message = try repository.sendUserMessage(
            conversationID: created.conversation.id,
            body: "Run the release build.",
            now: sentAt
        )

        XCTAssertEqual(message.author, .user)
        XCTAssertEqual(message.body, "Run the release build.")
        XCTAssertEqual(message.delivery, .delivered)
        XCTAssertEqual(
            try repository.loadMessages(conversationID: created.conversation.id),
            [message]
        )
        XCTAssertEqual(
            try repository.loadConversations().first?.updatedAt,
            sentAt
        )
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
        XCTAssertEqual(
            try repository.inlineImageDataURL(for: deliveredAttachment),
            "data:image/png;base64,aW1hZ2UgYnl0ZXM="
        )

        let inlineResult = MessengerCLI.run(arguments: [
            command.path, "--get-latest", "--peek", "--inline-images"
        ])
        XCTAssertEqual(inlineResult.exitCode, 0)
        let payload = try decode(MessengerInboxPayload.self, from: inlineResult.standardOutput)
        XCTAssertEqual(payload.deliveries.count, 1)
        XCTAssertEqual(payload.images, [MessengerInlineImage(
            attachmentID: attachment.id,
            originalFilename: "reference.png",
            mediaType: "image/png",
            dataURL: "data:image/png;base64,aW1hZ2UgYnl0ZXM="
        )])
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

        let replyBody = "The workspace bridge is ready — it's Unicode-safe. ✓"
        let encodedReplyBody = replyBody.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        )!
        let reply = MessengerCLI.run(arguments: [
            command.path,
            "--send",
            "--conversation", created.conversation.id.uuidString,
            "--body-percent-encoded", encodedReplyBody
        ])
        XCTAssertEqual(reply.exitCode, 0)
        let sent = try decode(ChatMessage.self, from: reply.standardOutput)
        XCTAssertEqual(sent.author, .agent(created.agent.id))
        XCTAssertEqual(sent.delivery, .delivered)
        XCTAssertEqual(sent.body, replyBody)
    }

    func testMessengerListsParticipantsWithPublicDescriptionsAndConversationActivity() throws {
        let firstActivity = Date(timeIntervalSince1970: 1_700_000_000)
        let secondActivity = Date(timeIntervalSince1970: 1_700_000_100)
        let first = try repository.createAgent(
            named: "Research Bot",
            publicDescription: "Finds and verifies evidence.",
            backstory: "SECRET RESEARCH BACKSTORY"
        )
        let second = try repository.createAgent(
            named: "Build Bot",
            publicDescription: "Turns plans into working software.",
            backstory: "SECRET BUILD BACKSTORY"
        )
        let group = try repository.createGroup(
            named: "Launch Room",
            publicDescription: "Coordinate a safe, evidence-backed launch.",
            participantIDs: [first.agent.id, second.agent.id],
            existingAgents: [first.agent, second.agent]
        )
        try repository.append(ChatMessage(
            conversationID: group.id,
            author: .agent(first.agent.id),
            body: "Evidence ready",
            createdAt: firstActivity,
            delivery: .delivered
        ))
        try repository.append(ChatMessage(
            conversationID: group.id,
            author: .agent(second.agent.id),
            body: "Build ready",
            createdAt: secondActivity,
            delivery: .delivered
        ))

        let command = repository.directory(for: first.agent)
            .appendingPathComponent(".agents/skills/messenger/messenger")
        let result = MessengerCLI.run(arguments: [
            command.path,
            "--list-participants",
            "--conversation", group.id.uuidString
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.standardOutput.contains("SECRET RESEARCH BACKSTORY"))
        XCTAssertFalse(result.standardOutput.contains("SECRET BUILD BACKSTORY"))
        let roster = try decode(MessengerRoster.self, from: result.standardOutput)
        XCTAssertEqual(roster.conversation.id, group.id)
        XCTAssertEqual(roster.conversation.publicDescription, "Coordinate a safe, evidence-backed launch.")
        XCTAssertEqual(roster.me.agentID, first.agent.id)
        XCTAssertEqual(roster.participants.map(\.participant.displayName), ["Research Bot", "Build Bot"])
        XCTAssertEqual(roster.participants.map(\.participant.handle), [.me, .bot])
        XCTAssertEqual(
            roster.participants.map(\.publicDescription),
            ["Finds and verifies evidence.", "Turns plans into working software."]
        )
        XCTAssertEqual(roster.participants.map(\.lastActiveAt), [firstActivity, secondActivity])
    }

    func testGroupDescriptionUpdateNotifiesEveryCurrentMember() throws {
        let first = try repository.createAgent(named: "Research Bot")
        let second = try repository.createAgent(named: "Build Bot")
        let agents = [first.agent, second.agent]
        let group = try repository.createGroup(
            named: "Launch Room",
            publicDescription: "Initial context",
            participantIDs: agents.map(\.id),
            existingAgents: agents
        )

        let updated = try repository.updateGroup(
            conversationID: group.id,
            named: group.displayName,
            publicDescription: "Ship the release after research and build checks pass.",
            participantIDs: group.participantIDs,
            existingAgents: agents
        )

        XCTAssertEqual(updated.publicDescription, "Ship the release after research and build checks pass.")
        for agent in agents {
            let delivery = try XCTUnwrap(repository.latestMessages(for: agent.id).first)
            XCTAssertEqual(
                delivery.message.body,
                "The group description was updated: Ship the release after research and build checks pass."
            )
            XCTAssertEqual(delivery.message.author, .system)
            XCTAssertEqual(
                delivery.conversation.publicDescription,
                "Ship the release after research and build checks pass."
            )
        }
    }

    func testMessengerCanSendMultipleFilesFromBotWorkspace() throws {
        let sender = try repository.createAgent(named: "Build Bot")
        let recipient = try repository.createAgent(named: "Review Bot")
        let group = try repository.createGroup(
            named: "Delivery Room",
            participantIDs: [sender.agent.id, recipient.agent.id],
            existingAgents: [sender.agent, recipient.agent]
        )
        let workspace = repository.directory(for: sender.agent)
        let report = workspace.appendingPathComponent("report.txt")
        let chart = workspace.appendingPathComponent("chart.png")
        let brief = workspace.appendingPathComponent("brief.pdf")
        try Data("finished report".utf8).write(to: report)
        try Data("image bytes".utf8).write(to: chart)
        try Data("%PDF-1.7 test document".utf8).write(to: brief)
        let command = workspace.appendingPathComponent(".agents/skills/messenger/messenger")

        let result = MessengerCLI.run(arguments: [
            command.path,
            "--send",
            "--conversation", group.id.uuidString,
            "--attach", report.path,
            "--attach", chart.path,
            "--attach", brief.path
        ])

        XCTAssertEqual(result.exitCode, 0)
        let sent = try decode(ChatMessage.self, from: result.standardOutput)
        XCTAssertEqual(sent.author, .agent(sender.agent.id))
        XCTAssertEqual(sent.body, "Sent 3 attachments")
        XCTAssertEqual(sent.attachments.count, 3)

        let attachments = try repository.loadAttachments(conversationID: group.id)
        let attachmentsByName = Dictionary(uniqueKeysWithValues: attachments.map {
            ($0.originalFilename, $0)
        })
        XCTAssertEqual(Set(attachmentsByName.keys), ["report.txt", "chart.png", "brief.pdf"])
        XCTAssertEqual(attachmentsByName["report.txt"]?.mediaType, "text/plain")
        XCTAssertEqual(attachmentsByName["chart.png"]?.mediaType, "image/png")
        XCTAssertEqual(attachmentsByName["brief.pdf"]?.mediaType, "application/pdf")
        let reportAttachment = try XCTUnwrap(attachmentsByName["report.txt"])
        XCTAssertEqual(
            try String(contentsOf: repository.attachmentFileURL(reportAttachment), encoding: .utf8),
            "finished report"
        )

        let delivery = try XCTUnwrap(
            repository.latestMessages(for: recipient.agent.id, consuming: false).first
        )
        XCTAssertEqual(delivery.sender.displayName, "Build Bot")
        XCTAssertEqual(
            delivery.attachments.map(\.originalFilename),
            ["report.txt", "chart.png", "brief.pdf"]
        )
    }

    func testMessengerRollsBackAttachmentsWhenAnyFileCannotBeImported() throws {
        let created = try repository.createAgent(named: "Build Bot")
        let workspace = repository.directory(for: created.agent)
        let validFile = workspace.appendingPathComponent("result.txt")
        try Data("result".utf8).write(to: validFile)
        let command = workspace.appendingPathComponent(".agents/skills/messenger/messenger")

        let result = MessengerCLI.run(arguments: [
            command.path,
            "--send",
            "--conversation", created.conversation.id.uuidString,
            "--body", "Results",
            "--attach", validFile.path,
            "--attach", workspace.appendingPathComponent("missing.txt").path
        ])

        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(try repository.loadAttachments(conversationID: created.conversation.id).isEmpty)
        XCTAssertTrue(try repository.loadMessages(conversationID: created.conversation.id).isEmpty)
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

    func testAgentMessagesNotifyEveryOtherGroupParticipant() throws {
        let first = try repository.createAgent(named: "First")
        let second = try repository.createAgent(named: "Second")
        let third = try repository.createAgent(named: "Third")
        let group = try repository.createGroup(
            named: "Team",
            participantIDs: [first.agent.id, second.agent.id, third.agent.id],
            existingAgents: [first.agent, second.agent, third.agent]
        )

        let firstMessage = try repository.sendAgentMessage(
            agentID: first.agent.id,
            conversationID: group.id,
            body: "First update"
        )
        let secondMessage = try repository.sendAgentMessage(
            agentID: second.agent.id,
            conversationID: group.id,
            body: "Second update"
        )

        XCTAssertEqual(
            try repository.notificationRecipientIDs(for: [firstMessage]),
            [second.agent.id, third.agent.id]
        )
        XCTAssertEqual(
            try repository.notificationRecipientIDs(for: [firstMessage, secondMessage]),
            [first.agent.id, second.agent.id, third.agent.id]
        )
    }

    func testAgentMessagesDoNotNotifyTheSenderInDirectConversation() throws {
        let created = try repository.createAgent(named: "Solo")
        let message = try repository.sendAgentMessage(
            agentID: created.agent.id,
            conversationID: created.conversation.id,
            body: "No self wake"
        )

        XCTAssertTrue(try repository.notificationRecipientIDs(for: [message]).isEmpty)
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
            environment: ["NOODLE_WORKSPACE": repository.directory(for: created.agent).path]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try decode([MessengerDelivery].self, from: result.standardOutput).count, 1)
    }

    func testReactionsPersistAndAreIdempotentPerAuthor() throws {
        let bot = try repository.createAgent(named: "Reactor")
        let message = try repository.sendUserMessage(conversationID: bot.conversation.id, body: "Build it")
        for author in [MessageAuthor.user, .agent(bot.agent.id), .agent(bot.agent.id)] {
            try repository.setReaction(conversationID: bot.conversation.id, messageID: message.id,
                                       author: author, emoji: "👍", present: true)
        }
        var saved = try XCTUnwrap(repository.loadMessages(conversationID: bot.conversation.id).first)
        XCTAssertEqual(saved.reactions?.count, 2)
        XCTAssertEqual(saved.reactionChanges?.count, 2)
        for _ in 0..<2 {
            try repository.setReaction(conversationID: bot.conversation.id, messageID: message.id,
                                       author: .agent(bot.agent.id), emoji: "👍", present: false)
        }
        saved = try XCTUnwrap(repository.loadMessages(conversationID: bot.conversation.id).first)
        XCTAssertEqual(saved.reactions?.map(\.author), [.user])
        XCTAssertEqual(saved.reactionChanges?.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(saved.reactionChanges?.last?.removed, true)
    }

    func testReactionFeedbackOnReadAndOwnMessagesIsDeliveredOnce() throws {
        let bot = try repository.createAgent(named: "Builder")
        let sent = try repository.sendAgentMessage(agentID: bot.agent.id,
                                                  conversationID: bot.conversation.id, body: "Done")
        XCTAssertTrue(try repository.latestMessages(for: bot.agent.id).isEmpty)
        let now = Date(timeIntervalSince1970: 1000)
        for present in [true, false, true] {
            try repository.setReaction(conversationID: bot.conversation.id, messageID: sent.id,
                                       author: .user, emoji: "❤️", present: present, now: now)
            let peek = try repository.latestMessages(for: bot.agent.id, consuming: false)
            XCTAssertEqual(peek.count, 1)
            let deliveries = try repository.latestMessages(for: bot.agent.id)
            XCTAssertEqual(deliveries.count, 1)
            XCTAssertEqual(deliveries.first?.sender.handle, .me)
            XCTAssertEqual(deliveries.first?.reactionChange?.sender.handle, .user)
            XCTAssertEqual(deliveries.first?.reactionChange?.removed, !present)
            XCTAssertEqual(deliveries.first?.message.id, sent.id)
            XCTAssertTrue(try repository.latestMessages(for: bot.agent.id).isEmpty)
        }
        try repository.setReaction(conversationID: bot.conversation.id, messageID: sent.id,
                                   author: .agent(bot.agent.id), emoji: "✅", present: true)
        XCTAssertTrue(try repository.latestMessages(for: bot.agent.id).isEmpty)
    }

    func testMessengerCLIReactionsAndHistoryIdentifyEachReactor() throws {
        let first = try repository.createAgent(named: "First")
        let second = try repository.createAgent(named: "Second")
        let group = try repository.createGroup(named: "Team", participantIDs: [first.agent.id, second.agent.id],
                                               existingAgents: [first.agent, second.agent])
        let message = try repository.sendUserMessage(conversationID: group.id, body: "Start")
        _ = try repository.latestMessages(for: second.agent.id)
        let command = repository.directory(for: first.agent).appendingPathComponent(".agents/skills/messenger/messenger").path
        let args = ["--conversation", group.id.uuidString, "--message", message.id.uuidString, "--emoji", "👀"]
        XCTAssertEqual(MessengerCLI.run(arguments: [command, "--react"] + args).exitCode, 0)
        let receivingCommand = repository.directory(for: second.agent)
            .appendingPathComponent(".agents/skills/messenger/messenger").path
        let inbox = MessengerCLI.run(arguments: [receivingCommand, "--get-latest"])
        XCTAssertEqual(inbox.exitCode, 0)
        let feedback = try decode([MessengerDelivery].self, from: inbox.standardOutput)
        XCTAssertEqual(feedback.count, 1)
        XCTAssertEqual(feedback.first?.message.id, message.id)
        XCTAssertEqual(feedback.first?.reactionChange?.emoji, "👀")
        XCTAssertEqual(feedback.first?.reactionChange?.removed, false)
        XCTAssertEqual(feedback.first?.reactionChange?.sender.displayName, "First")
        XCTAssertEqual(feedback.first?.reactionChange?.sender.handle, .bot)
        let history = MessengerCLI.run(arguments: [command, "--list-messages", "--conversation", group.id.uuidString])
        XCTAssertEqual(history.exitCode, 0)
        let deliveries = try decode([MessengerDelivery].self, from: history.standardOutput)
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?.reactions?.first?.sender.handle, .me)
        XCTAssertEqual(try repository.latestMessages(for: first.agent.id).count, 1, "History must not consume unread messages")
        XCTAssertEqual(MessengerCLI.run(arguments: [command, "--unreact"] + args).exitCode, 0)
        let removal = MessengerCLI.run(arguments: [receivingCommand, "--get-latest"])
        XCTAssertEqual(removal.exitCode, 0)
        let removed = try decode([MessengerDelivery].self, from: removal.standardOutput)
        XCTAssertEqual(removed.first?.reactionChange?.removed, true)
        XCTAssertEqual(removed.first?.reactionChange?.emoji, "👀")
        let consumed = MessengerCLI.run(arguments: [receivingCommand, "--get-latest"])
        XCTAssertEqual(consumed.exitCode, 0)
        XCTAssertTrue(try decode([MessengerDelivery].self, from: consumed.standardOutput).isEmpty)
        XCTAssertNotEqual(MessengerCLI.run(arguments: [command, "--react", "--unreact"] + args).exitCode, 0)
        XCTAssertNotEqual(MessengerCLI.run(arguments: [command, "--react", "--emoji", "👍"]).exitCode, 0)
    }

    func testReactionsRejectInvalidEmojiAndNonparticipants() throws {
        let first = try repository.createAgent(named: "First")
        let outsider = try repository.createAgent(named: "Outsider")
        let message = try repository.sendUserMessage(conversationID: first.conversation.id, body: "Private")
        for emoji in ["", "hello", "1", "👍👍"] {
            XCTAssertThrowsError(try repository.setReaction(conversationID: first.conversation.id,
                messageID: message.id, author: .user, emoji: emoji, present: true))
        }
        for emoji in ["👍🏽", "👨‍👩‍👧‍👦", "🇬🇧", "1️⃣", "❤️"] {
            XCTAssertTrue(MessageReaction.isValidEmoji(emoji), emoji)
        }
        XCTAssertThrowsError(try repository.setReaction(conversationID: first.conversation.id,
            messageID: message.id, author: .agent(outsider.agent.id), emoji: "👍", present: true))
        XCTAssertThrowsError(try repository.setReaction(conversationID: first.conversation.id,
            messageID: UUID(), author: .user, emoji: "👍", present: true))
        XCTAssertThrowsError(try repository.latestMessages(for: outsider.agent.id, in: first.conversation.id, includingRead: true))
    }

    func testLegacyMessagesAndInboxesDecodeWithoutReactions() throws {
        let message = ChatMessage(conversationID: UUID(), author: .user, body: "Old", delivery: .delivered)
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(message)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("reactions"))
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: encoded).reactions)
        XCTAssertNil(try JSONDecoder().decode(AgentInbox.self, from: Data("{\"conversationOffsets\":{}}".utf8)).reactionOffsets)
    }

    func testNewGroupMemberDoesNotReceiveHistoricalReactions() throws {
        let first = try repository.createAgent(named: "First")
        let second = try repository.createAgent(named: "Second")
        let third = try repository.createAgent(named: "Third")
        let group = try repository.createGroup(named: "Team", participantIDs: [first.agent.id, second.agent.id],
                                               existingAgents: [first.agent, second.agent, third.agent])
        let message = try repository.sendUserMessage(conversationID: group.id, body: "Before joining")
        try repository.setReaction(conversationID: group.id, messageID: message.id,
                                   author: .user, emoji: "👍", present: true)
        _ = try repository.updateGroupParticipants(conversationID: group.id,
            participantIDs: [first.agent.id, second.agent.id, third.agent.id],
            existingAgents: [first.agent, second.agent, third.agent])
        XCTAssertEqual(try repository.latestMessages(for: third.agent.id).first?.message.author, .system)
        try repository.setReaction(conversationID: group.id, messageID: message.id,
                                   author: .user, emoji: "✅", present: true)
        XCTAssertEqual(try repository.latestMessages(for: third.agent.id).first?.reactionChange?.emoji, "✅")
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from string: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(string.utf8))
    }
}
