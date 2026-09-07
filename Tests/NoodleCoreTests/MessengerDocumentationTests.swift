import XCTest
@testable import NoodleCore

final class MessengerDocumentationTests: XCTestCase {
    func testReferenceIsCurrentAndEveryRuntimeCaseHasGuidance() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let checkedIn = try String(contentsOf: root.appendingPathComponent("docs/message-reference.md"), encoding: .utf8)
        XCTAssertEqual(checkedIn, MessengerDocumentation.referenceMarkdown,
            "Regenerate with swift run --disable-sandbox NoodleDocumentation --write docs/message-reference.md")
        let entries = MessengerDocumentation.eventReferences
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "Event identifiers must be unique.")
        for entry in entries {
            XCTAssertFalse(entry.guidance.isEmpty, entry.id)
            XCTAssertFalse(entry.fields.isEmpty, entry.id)
            XCTAssertFalse(entry.recipients.isEmpty, entry.id)
            XCTAssertTrue(MessengerDocumentation.agentInstructions.contains(entry.guidance), entry.id)
        }
        XCTAssertEqual(Set(AgentWakeReason.allCases.map(\.rawValue)),
                       Set(AgentWakeReason.allCases.map { $0.reference.id }))
        for command in MessengerCommandKind.allCases {
            XCTAssertFalse(command.guidance.isEmpty)
            XCTAssertTrue(command.usage.hasPrefix(command.rawValue))
            XCTAssertTrue(MessengerDocumentation.cliHelp.contains(command.usage))
            XCTAssertTrue(checkedIn.contains(command.usage))
        }
    }

    func testEncodedDeliveryAndMessageFieldsAreDocumented() throws {
        let botID = UUID()
        let conversation = BotConversation(displayName: "Team", kind: .group, participantIDs: [botID])
        let me = MessengerIdentity(handle: .me, agentID: botID, displayName: "Bot")
        var message = ChatMessage(conversationID: conversation.id, author: .user, body: "Hello",
                                  delivery: .delivered, attachmentIDs: [UUID()])
        message.reactions = [MessageReaction(id: UUID(), author: .agent(botID), emoji: "✅", createdAt: Date())]
        message.reactionChanges = [MessageReactionChange(id: UUID(), conversationID: conversation.id,
            messageID: message.id, sequence: 1, author: .agent(botID), emoji: "✅", removed: false, createdAt: Date())]
        var delivery = MessengerDelivery(me: me, conversation: conversation, participants: [me],
            sender: .init(handle: .user, displayName: "User"), message: message, attachments: [])
        delivery.reactions = [.init(emoji: "✅", sender: me)]
        delivery.reactionChange = .init(id: UUID(), emoji: "✅", removed: false, sender: me, createdAt: Date())

        func check<T: Encodable>(_ value: T, fields: [(String, String)]) throws {
            let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            let documented = Set(fields.map { $0.0 })
            XCTAssertEqual(Set(wire.keys), documented)
            // Also detect new optional stored fields even when a fixture leaves them nil.
            XCTAssertEqual(Set(Mirror(reflecting: value).children.compactMap(\.label)), documented)
        }
        try check(message, fields: MessengerDocumentation.messageFields)
        try check(delivery, fields: MessengerDocumentation.deliveryFields)
        XCTAssertEqual(delivery.kind, .reactionChange)
        delivery.reactionChange = nil
        XCTAssertEqual(delivery.kind, .message)
        let notice = MessengerDelivery(me: me, conversation: conversation, participants: [me],
            sender: .init(handle: .system, displayName: "Noodle"),
            message: ChatMessage(conversationID: conversation.id, author: .system, body: "Joined", delivery: .delivered),
            attachments: [])
        XCTAssertEqual(notice.kind, .systemNotice)
    }

    func testWorkspaceRefreshUsesCatalogueAndPreservesBotContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-docs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Writer")
        let workspace = repository.directory(for: bot.agent)
        let guide = workspace.appendingPathComponent("AGENTS.md")
        try """
        # Noodle Agent

        ## Backstory

        PRIVATE-BACKSTORY-TO-PRESERVE

        <!-- noodle:managed:start -->
        Obsolete runtime guidance.
        <!-- noodle:managed:end -->
        """.write(to: guide, atomically: true, encoding: .utf8)
        let custom = workspace.appendingPathComponent(".agents/skills/custom", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try "My custom skill".write(to: custom.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try repository.synchronizeAgentWorkspace(bot.agent)
        let refreshed = try String(contentsOf: guide, encoding: .utf8)
        let skill = try String(contentsOf: workspace.appendingPathComponent(".agents/skills/messenger/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(refreshed.contains("PRIVATE-BACKSTORY-TO-PRESERVE"))
        XCTAssertFalse(refreshed.contains("Obsolete runtime guidance"))
        XCTAssertTrue(refreshed.contains(MessengerDocumentation.agentInstructions))
        XCTAssertTrue(skill.contains(MessengerDocumentation.agentInstructions))
        XCTAssertFalse(skill.contains("PRIVATE-BACKSTORY-TO-PRESERVE"))
        XCTAssertEqual(try String(contentsOf: custom.appendingPathComponent("SKILL.md"), encoding: .utf8), "My custom skill")
    }

    func testDocumentedCommandsDispatchAndHelpUsesCatalogue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-cli-docs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Tester")
        let message = ChatMessage(conversationID: bot.conversation.id, author: .user, body: "Test", delivery: .delivered)
        try repository.append(message)
        let prefix = ["messenger", "--agent-directory", repository.directory(for: bot.agent).path]
        let conversation = ["--conversation", bot.conversation.id.uuidString]
        for command in MessengerCommandKind.allCases {
            let options: [String]
            switch command {
            case .help, .listEffects, .getLatest, .listConversations: options = []
            case .effect: options = ["confetti"] + conversation
            case .listMessages, .listParticipants: options = conversation
            case .react, .unreact: options = conversation + ["--message", message.id.uuidString, "--emoji", "✅"]
            case .send: options = conversation + ["--body", "Reply"]
            }
            let result = MessengerCLI.run(arguments: prefix + [command.rawValue] + options, environment: [:])
            XCTAssertEqual(result.exitCode, 0, "\(command): \(result.standardError)")
            if command == .help {
                XCTAssertEqual(result.standardOutput, MessengerDocumentation.cliHelp + "\n")
            }
        }
    }
}
