import BrowserBridge
import XCTest
@testable import NoodleCore

final class ToolHostServicesTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private var agent: AgentRecord!
    private var conversation: BotConversation!
    private var othersConversation: BotConversation!
    private let assigned = UUID(), unassigned = UUID()
    private var host: ToolHostServices!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root)
        let a = try repository.createAgent(named: "Caller"), b = try repository.createAgent(named: "Other")
        agent = a.agent; conversation = a.conversation; othersConversation = b.conversation
        host = .repository(repository) { [assigned] _ in ["browser": [assigned.uuidString]] }
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func card(_ browser: UUID) throws -> ToolPost {
        let reference = BrowserReference(browser: RemoteBrowser(id: browser, name: "Work"), tabID: UUID(), url: "https://example.com", title: "Example")
        return try ToolPost(["message": "See this", "attachment": ["filename": "Example.noodlebrowser", "mediaType": BrowserReference.mediaType,
                                                                  "data": try JSONEncoder().encode(reference).base64EncodedString()]])
    }

    func testMembershipComesFromTheRepository() {
        XCTAssertTrue(host.isMember(agent.id, conversation.id))
        XCTAssertFalse(host.isMember(agent.id, othersConversation.id))
        XCTAssertFalse(host.isMember(UUID(), conversation.id))
    }

    func testABrowserCardIsPostedAsTheBotOnlyForAnAssignedBrowser() throws {
        let id = try host.post(try card(assigned), agent.id, conversation.id)
        let attachment = try XCTUnwrap(repository.loadAttachments(conversationID: conversation.id).first { $0.id == id })
        XCTAssertEqual(attachment.browser?.agentID, agent.id)
        XCTAssertEqual(attachment.browser?.reference.browser.id, assigned)
        let message = try XCTUnwrap(repository.loadMessages(conversationID: conversation.id).last)
        XCTAssertEqual(message.body, "See this")
        XCTAssertEqual(message.attachmentIDs, [id])

        let before = try repository.loadAttachments(conversationID: conversation.id).count
        XCTAssertThrowsError(try host.post(try card(unassigned), agent.id, conversation.id), "a card for a browser the bot was not assigned")
        XCTAssertThrowsError(try host.post(try card(assigned), agent.id, othersConversation.id), "a conversation the bot is not in")
        XCTAssertEqual(try repository.loadAttachments(conversationID: conversation.id).count, before)
        XCTAssertTrue(try repository.loadAttachments(conversationID: othersConversation.id).isEmpty)
    }

    func testOrdinaryFilesPostWithoutACardAndReservedNoodleTypesAreRefused() throws {
        let file = try ToolPost(["attachment": ["filename": "notes.txt", "mediaType": "text/plain", "data": Data("hello".utf8).base64EncodedString()]])
        let id = try host.post(file, agent.id, conversation.id)
        let attachment = try XCTUnwrap(repository.loadAttachments(conversationID: conversation.id).first { $0.id == id })
        XCTAssertNil(attachment.browser)
        XCTAssertEqual(try repository.loadMessages(conversationID: conversation.id).last?.body, "notes.txt")
        let spoof = try ToolPost(["attachment": ["filename": "c.noodlecomputer", "mediaType": "application/vnd.noodle.computer+json", "data": "e30="]])
        XCTAssertThrowsError(try host.post(spoof, agent.id, conversation.id))
    }
}
