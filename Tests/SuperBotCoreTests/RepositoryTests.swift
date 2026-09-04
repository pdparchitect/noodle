import XCTest
@testable import SuperBotCore

final class RepositoryTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superbot-tests-\(UUID().uuidString)", isDirectory: true)
        repository = WorkspaceRepository(rootURL: root)
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
        XCTAssertEqual(created.conversation.participantIDs, [created.agent.id])
    }

    func testRenameDoesNotMoveWorkspace() throws {
        let created = try repository.createAgent(named: "Research Bot")
        let originalDirectory = repository.directory(for: created.agent)
        let renamed = try repository.renameAgent(created.agent, to: "Evidence Bot")

        XCTAssertEqual(renamed.id, created.agent.id)
        XCTAssertEqual(repository.directory(for: renamed), originalDirectory)
        XCTAssertEqual(try repository.loadAgents().first?.displayName, "Evidence Bot")
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
}
