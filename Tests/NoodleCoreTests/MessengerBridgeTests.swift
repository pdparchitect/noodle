import XCTest
@testable import NoodleCore

final class MessengerBridgeTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private var agent: AgentRecord!
    private var other: AgentRecord!
    private var conversation: BotConversation!
    private var privateConversation: BotConversation!
    private var broker: MessengerBroker!
    private var workspace: URL { repository.directory(for: agent) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root)
        let a = try repository.createAgent(named: "Caller"), b = try repository.createAgent(named: "Other")
        agent = a.agent; other = b.agent; conversation = a.conversation; privateConversation = b.conversation
        broker = MessengerBroker(repository: repository)
        try broker.start(agents: [agent, other])
    }
    override func tearDownWithError() throws { broker?.stop(); try? FileManager.default.removeItem(at: root) }
    private func call(_ action: MessengerAction) throws -> MessengerCommandResult {
        try MessengerBridgeClient.request(action, workspace: workspace)
    }
    private func decode<T: Decodable>(_ result: MessengerCommandResult, as: T.Type) throws -> T {
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(result.standardOutput.utf8))
    }

    func testCLIUsesBrokerAndCannotReadNonmemberConversation() throws {
        let result = MessengerCLI.run(arguments: ["messenger", "--agent-directory", workspace.path, "--list-conversations"])
        let conversations = try decode(result, as: [BotConversation].self)
        XCTAssertEqual(conversations.map(\.id), [conversation.id])
        XCTAssertNotEqual(try call(.listMessages(conversationID: privateConversation.id)).exitCode, 0)
        XCTAssertNotEqual(try call(.listParticipants(conversationID: privateConversation.id)).exitCode, 0)
        XCTAssertNotEqual(try call(.send(conversationID: privateConversation.id, body: "forged", attachmentURLs: [])).exitCode, 0)
        XCTAssertFalse(try repository.loadMessages(conversationID: privateConversation.id).contains { $0.body == "forged" })
    }

    func testMissingBridgeDoesNotFallBackToRepositoryFiles() throws {
        broker.stop()
        let mailbox = try WorkspaceMailbox(workspace: workspace, path: MessengerBridgeClient.path)
        mailbox.remove("session.json")
        let result = MessengerCLI.run(arguments: ["messenger", "--agent-directory", workspace.path, "--list-conversations"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.contains("bridge is unavailable"))
    }

    func testMembershipRevocationTakesEffectWithoutRestartingBroker() throws {
        let group = try repository.createGroup(named: "Shared", participantIDs: [agent.id, other.id], existingAgents: [agent, other])
        XCTAssertEqual(try call(.send(conversationID: group.id, body: "before removal", attachmentURLs: [])).exitCode, 0)
        _ = try repository.updateGroupParticipants(conversationID: group.id, participantIDs: [other.id], existingAgents: [agent, other])
        XCTAssertNotEqual(try call(.listMessages(conversationID: group.id)).exitCode, 0)
        XCTAssertNotEqual(try call(.listParticipants(conversationID: group.id)).exitCode, 0)
        XCTAssertNotEqual(try call(.send(conversationID: group.id, body: "after removal", attachmentURLs: [])).exitCode, 0)
        let deliveries = try decode(call(.getLatest(consumes: false, includesInlineImages: false)), as: [MessengerDelivery].self)
        XCTAssertFalse(deliveries.contains { $0.message.conversationID == group.id })
        XCTAssertFalse(try repository.loadMessages(conversationID: group.id).contains { $0.body == "after removal" })
    }

    func testAnotherBotsTokenCannotAuthorizeRequestsFromCallerWorkspace() throws {
        let otherMailbox = try WorkspaceMailbox(workspace: repository.directory(for: other), path: MessengerBridgeClient.path)
        let otherSession = try JSONDecoder().decode(MCPBridgeSession.self, from: otherMailbox.read("session.json", limit: 4096))
        let ownMailbox = try WorkspaceMailbox(workspace: workspace, path: MessengerBridgeClient.path)
        // Even if a foreign token were known, the broker binds it to its own
        // workspace. Replacing the client session file cannot change identity.
        try ownMailbox.write(otherSession, named: "session.json")
        XCTAssertNotEqual(try call(.listMessages(conversationID: privateConversation.id)).exitCode, 0)
        XCTAssertNotEqual(try call(.send(conversationID: privateConversation.id, body: "impersonated", attachmentURLs: [])).exitCode, 0)
        XCTAssertFalse(try repository.loadMessages(conversationID: privateConversation.id).contains { $0.body == "impersonated" })
    }

    func testOversizedRequestIsRejectedBeforeCreatingMailboxRequest() throws {
        XCTAssertThrowsError(try call(.send(conversationID: conversation.id,
            body: String(repeating: "x", count: MessengerBridgeClient.maxRequestBytes), attachmentURLs: [])))
        let mailbox = try WorkspaceMailbox(workspace: workspace, path: MessengerBridgeClient.path)
        XCTAssertFalse(try mailbox.names().contains { $0.hasSuffix(".request") })
    }

    func testAttachmentUploadAndInboxCopyStayInsideCallerWorkspace() throws {
        let source = workspace.appendingPathComponent("picture.txt")
        try Data("own attachment".utf8).write(to: source)
        let sent = try decode(call(.send(conversationID: conversation.id, body: "file", attachmentURLs: [source])), as: ChatMessage.self)
        XCTAssertEqual(sent.attachments.count, 1)
        let deliveries = try decode(call(.listMessages(conversationID: conversation.id)), as: [MessengerDelivery].self)
        let file = try XCTUnwrap(deliveries.flatMap(\.attachments).first)
        XCTAssertTrue(file.absolutePath.hasPrefix(workspace.path + "/.noodle/messenger-attachments/"))
        XCTAssertEqual(try String(contentsOfFile: file.absolutePath, encoding: .utf8), "own attachment")
        XCTAssertFalse(file.absolutePath.hasPrefix(repository.conversationDirectory(id: conversation.id).path))
    }

    func testAttachmentCannotReadAnotherBotOrFollowALink() throws {
        let source = repository.directory(for: other).appendingPathComponent("private.txt")
        try Data("private".utf8).write(to: source)
        let link = workspace.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        for path in [source, link] {
            XCTAssertNotEqual(try call(.send(conversationID: conversation.id, body: "leak", attachmentURLs: [path])).exitCode, 0)
        }
        XCTAssertTrue(try repository.loadAttachments(conversationID: conversation.id).isEmpty)
    }

    func testRedirectedAttachmentDestinationDoesNotConsumeInboxOrOverwriteOtherBot() throws {
        let attachment = try repository.importAttachment(data: Data("payload".utf8), originalFilename: "a.txt",
            into: conversation.id, mediaType: "text/plain")
        try repository.append(ChatMessage(conversationID: conversation.id, author: .user, body: "attachment",
            delivery: .queued, attachmentIDs: [attachment.id]))
        let redirect = workspace.appendingPathComponent(".noodle/messenger-attachments")
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: repository.directory(for: other))
        XCTAssertNotEqual(try call(.getLatest(consumes: true, includesInlineImages: false)).exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: other).appendingPathComponent(conversation.id.uuidString.lowercased()).path))
        try FileManager.default.removeItem(at: redirect)
        let deliveries = try decode(call(.getLatest(consumes: true, includesInlineImages: false)), as: [MessengerDelivery].self)
        XCTAssertTrue(deliveries.contains { $0.message.body == "attachment" })
    }

    func testForgedExpiredRevokedAndReplayedRequestsCannotSend() throws {
        let mailbox = try WorkspaceMailbox(workspace: workspace, path: MessengerBridgeClient.path)
        let session = try JSONDecoder().decode(MCPBridgeSession.self, from: mailbox.read("session.json", limit: 4096))
        func submit(_ request: MessengerBridgeRequest) throws -> MessengerCommandResult {
            let stem = request.id.uuidString.lowercased()
            mailbox.remove(stem + ".response")
            try mailbox.write(request, named: stem + ".request")
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let data = try? mailbox.read(stem + ".response", limit: 1_048_576) {
                    return try JSONDecoder().decode(MessengerCommandResult.self, from: data)
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            throw HarnessSetupError("Broker did not answer the fixture request")
        }
        let action = MessengerAction.send(conversationID: conversation.id, body: "once", attachmentURLs: [])
        XCTAssertNotEqual(try submit(.init(session: "forged", action: action)).exitCode, 0)
        XCTAssertNotEqual(try submit(.init(session: session.token, action: action, expiresAt: Date().addingTimeInterval(-1))).exitCode, 0)
        let valid = MessengerBridgeRequest(session: session.token, action: action)
        XCTAssertEqual(try submit(valid).exitCode, 0)
        XCTAssertNotEqual(try submit(valid).exitCode, 0)
        broker.stop(); try broker.start(agents: [agent, other])
        XCTAssertNotEqual(try submit(.init(session: session.token, action: action)).exitCode, 0)
        XCTAssertEqual(try repository.loadMessages(conversationID: conversation.id).filter { $0.body == "once" }.count, 1)
    }
}
