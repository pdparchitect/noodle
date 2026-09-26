import BrowserBridge
import ComputerBridge
import Foundation
import NoodleCore
import XCTest

// TODO(0.29.0): Remove with CompanionCardMigration.
final class CompanionCardMigrationTests: XCTestCase {
    /// Writes an attachment as versions up to 0.27 saved browser and computer cards: a file, with the card beside it.
    private struct Legacy<Card: Encodable>: Encodable {
        let id: UUID, conversationID: UUID, originalFilename: String, storedFilename: String, mediaType: String
        let byteCount: Int64, createdAt: Date, browser: Card?, computer: Card?
    }

    private func legacy<Card: Encodable>(_ card: Card, key: String, mediaType: String, filename: String, data: Data,
                                         in conversation: UUID, repository: WorkspaceRepository) throws -> UUID {
        let id = UUID(), stored = id.uuidString.lowercased() + "-" + filename
        let directory = repository.attachmentsDirectory(conversationID: conversation)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(stored))
        let record = Legacy(id: id, conversationID: conversation, originalFilename: filename, storedFilename: stored, mediaType: mediaType,
                            byteCount: Int64(data.count), createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                            browser: key == "browser" ? card : nil, computer: key == "computer" ? card : nil)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: directory.appendingPathComponent(id.uuidString.lowercased() + ".json"))
        return id
    }

    func testSavedCardsBecomeLinksKeepingTheirIDsAndPictures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Alfred")
        let conversation = bot.conversation.id

        let tab = UUID(), image = Data([0xFF, 0xD8, 0xFF])
        let page = BrowserReference(browser: RemoteBrowser(id: UUID(), name: "Work", symbol: "briefcase", colour: 2), tabID: tab,
                                    url: "https://example.com/plans", title: "Plans", previewImage: image)
        let browserCard = try legacy(BrowserCard(reference: page, agentID: bot.agent.id), key: "browser", mediaType: BrowserReference.mediaType,
                                     filename: "Plans.noodlebrowser", data: JSONEncoder().encode(page), in: conversation, repository: repository)
        let terminal = UUID()
        let box = ComputerCard(computer: RemoteComputer(id: UUID(), name: "Build box", kind: "Linux", state: "Running", symbol: "hammer"),
                               agentID: bot.agent.id, terminalID: terminal, terminalPreview: "$ make", view: "terminal")
        let computerCard = try legacy(box, key: "computer", mediaType: ComputerCard.mediaType, filename: "Build box.noodlecomputer",
                                      data: JSONEncoder().encode(box.reference), in: conversation, repository: repository)
        let file = try repository.importAttachment(data: Data("notes".utf8), originalFilename: "notes.txt", into: conversation, mediaType: "text/plain")

        CompanionCardMigration.run(repository)
        let attachments = Dictionary(uniqueKeysWithValues: try repository.loadAttachments(conversationID: conversation).map { ($0.id, $0) })

        let browser = try XCTUnwrap(attachments[browserCard])
        XCTAssertEqual(browser.companion, .browser(page.browser.id, tab: tab))
        XCTAssertEqual(browser.card?.title, "Plans")
        XCTAssertEqual(browser.card?.detail, "https://example.com/plans")
        XCTAssertEqual(browser.card?.image, image)
        XCTAssertEqual(browser.createdAt, Date(timeIntervalSince1970: 1_790_000_000))
        let computer = try XCTUnwrap(attachments[computerCard])
        XCTAssertEqual(computer.companion, .computer(box.computer.id, terminal: terminal, view: "terminal"))
        XCTAssertEqual(computer.card?.detail, "$ make")
        XCTAssertNil(attachments[file.id]?.card, "an ordinary file gained a card")
        XCTAssertNil(attachments[file.id]?.url, "an ordinary file became a link")
        XCTAssertEqual(attachments[file.id]?.storedFilename, file.storedFilename)

        let stored = try FileManager.default.contentsOfDirectory(atPath: repository.attachmentsDirectory(conversationID: conversation).path)
        XCTAssertFalse(stored.contains { $0.hasSuffix(".noodlebrowser") || $0.hasSuffix(".noodlecomputer") }, "an old card file stayed")

        CompanionCardMigration.run(repository)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try repository.loadAttachments(conversationID: conversation).map { ($0.id, $0) }),
                       attachments, "running again changed something")
    }
}
