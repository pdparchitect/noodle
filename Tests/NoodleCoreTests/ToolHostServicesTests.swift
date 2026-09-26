import BrowserBridge
import ComputerBridge
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

    func testABrowserIsSharedAsALinkByTheBotOnlyForAnAssignedBrowser() throws {
        let id = try host.post(try card(assigned), agent.id, conversation.id)
        let attachment = try XCTUnwrap(repository.loadAttachments(conversationID: conversation.id).first { $0.id == id })
        guard case .browser(let browser, let tab)? = attachment.companion else { return XCTFail("not a browser link") }
        XCTAssertEqual(browser, assigned)
        XCTAssertNotNil(tab)
        XCTAssertEqual(attachment.card?.title, "Example")
        XCTAssertEqual(attachment.card?.detail, "https://example.com")
        let message = try XCTUnwrap(repository.loadMessages(conversationID: conversation.id).last)
        XCTAssertEqual(message.body, "See this")
        XCTAssertEqual(message.attachmentIDs, [id])

        let before = try repository.loadAttachments(conversationID: conversation.id).count
        XCTAssertThrowsError(try host.post(try card(unassigned), agent.id, conversation.id), "a card for a browser the bot was not assigned")
        XCTAssertThrowsError(try host.post(try card(assigned), agent.id, othersConversation.id), "a conversation the bot is not in")
        XCTAssertEqual(try repository.loadAttachments(conversationID: conversation.id).count, before)
        XCTAssertTrue(try repository.loadAttachments(conversationID: othersConversation.id).isEmpty)
    }

    func testAComputerIsSharedAsALinkOnlyForAnAssignedComputerAndKeepsItsCaptureTime() throws {
        let computers = ToolHostServices.repository(repository) { [assigned] _ in ["computer": [assigned.uuidString]] }
        func card(_ computer: UUID) throws -> ToolPost {
            let reference = ComputerReference(computer: RemoteComputer(id: computer, name: "Build box", kind: "Shell", state: "Running", symbol: "terminal"),
                                              terminalID: UUID(), capturedAt: Date(timeIntervalSince1970: 1_700_000_000), terminalPreview: "ok", view: "terminal")
            return try ToolPost(["attachment": ["filename": "Build box.noodlecomputer", "mediaType": ComputerCard.mediaType,
                                                "data": try JSONEncoder().encode(reference).base64EncodedString()]])
        }
        let id = try computers.post(try card(assigned), agent.id, conversation.id)
        let attachment = try XCTUnwrap(repository.loadAttachments(conversationID: conversation.id).first { $0.id == id })
        guard case .computer(let computer, let terminal, let view)? = attachment.companion else { return XCTFail("not a computer link") }
        XCTAssertEqual(computer, assigned)
        XCTAssertNotNil(terminal)
        XCTAssertEqual(view, "terminal")
        XCTAssertEqual(attachment.card?.capturedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(attachment.card?.detail, "ok")
        XCTAssertThrowsError(try computers.post(try card(unassigned), agent.id, conversation.id))
        XCTAssertThrowsError(try host.post(try card(assigned), agent.id, conversation.id), "assigned as a browser is not assigned as a computer")

        // A tool that sends the computer's private description anyway never gets it into the conversation.
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: try card(assigned).data) as? [String: Any])
        var described = try XCTUnwrap(fields["computer"] as? [String: Any])
        described["description"] = "Release builds only."
        fields["computer"] = described
        let leaked = try computers.post(try ToolPost(["attachment": ["filename": "Build box.noodlecomputer", "mediaType": ComputerCard.mediaType,
            "data": try JSONSerialization.data(withJSONObject: fields).base64EncodedString()]]), agent.id, conversation.id)
        let stored = try XCTUnwrap(repository.loadAttachments(conversationID: conversation.id).first { $0.id == leaked })
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(stored), as: UTF8.self).contains("Release builds only."))
        XCTAssertFalse(String(decoding: try Data(contentsOf: repository.attachmentFileURL(stored)), as: UTF8.self).contains("Release builds only."))
    }

    func testOrdinaryFilesPostWithoutACardAndReservedNoodleTypesAreRefused() throws {
        let file = try ToolPost(["attachment": ["filename": "notes.txt", "mediaType": "text/plain", "data": Data("hello".utf8).base64EncodedString()]])
        let id = try host.post(file, agent.id, conversation.id)
        let attachment = try XCTUnwrap(repository.loadAttachments(conversationID: conversation.id).first { $0.id == id })
        XCTAssertNil(attachment.card)
        XCTAssertEqual(try repository.loadMessages(conversationID: conversation.id).last?.body, "notes.txt")
        let spoof = try ToolPost(["attachment": ["filename": "a.noodleapplet", "mediaType": "application/vnd.noodle.applet+json", "data": "e30="]])
        XCTAssertThrowsError(try host.post(spoof, agent.id, conversation.id))
    }
}
