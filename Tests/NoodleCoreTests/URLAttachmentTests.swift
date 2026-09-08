import XCTest
@testable import NoodleCore

final class URLAttachmentTests: XCTestCase {
    func testPathsAndFileURLsRemainLocal() throws {
        let directory = URL(fileURLWithPath: "/tmp/work", isDirectory: true)
        XCTAssertEqual(try AttachmentSource.resolve("image.png", relativeTo: directory).path, "/tmp/work/image.png")
        XCTAssertEqual(try AttachmentSource.resolve("../image.png", relativeTo: directory).path, "/tmp/image.png")
        XCTAssertEqual(try AttachmentSource.resolve("/tmp/a b#c.png", relativeTo: directory).path, "/tmp/a b#c.png")
        let file = URL(fileURLWithPath: "/tmp/a b#c.png")
        XCTAssertEqual(try AttachmentSource.resolve(file.absoluteString, relativeTo: directory), file)
        XCTAssertEqual(try AttachmentSource.resolve("file://localhost/tmp/a.png", relativeTo: directory).path, "/tmp/a.png")
        XCTAssertTrue(try AttachmentSource.resolve("./https:notes.txt", relativeTo: directory).isFileURL)
    }

    func testOnlyValidPublicWebURLsBecomeLinks() throws {
        let directory = URL(fileURLWithPath: "/tmp")
        for value in ["http://example.com/page", "https://example.com/a?q=hello%20world#section", "HTTPS://EXAMPLE.COM/a"] {
            let resolved = try AttachmentSource.resolve(value, relativeTo: directory)
            XCTAssertFalse(resolved.isFileURL)
            XCTAssertEqual(resolved.host, "example.com")
        }
        XCTAssertEqual(try AttachmentSource.resolve("https://example.com/a#section", relativeTo: directory).fragment, "section")
        for value in ["", "ftp://example.com/a", "javascript:alert(1)", "data:text/plain,hello", "mailto:a@example.com",
                      "https:///a", "http://localhost/a", "http://127.0.0.1/a", "https://192.168.1.1/a", "https://name:secret@example.com/a",
                      "file://remote-host/tmp/a", "file:///tmp/a?query", "file:///tmp/a#fragment"] {
            XCTAssertThrowsError(try AttachmentSource.resolve(value, relativeTo: directory), value)
        }
    }

    func testLinkPersistenceDeliveryAndLegacyFileDecoding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-url-persistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let first = try repository.createAgent(named: "First")
        let second = try repository.createAgent(named: "Second")
        let group = try repository.createGroup(named: "Links", participantIDs: [first.agent.id, second.agent.id], existingAgents: [first.agent, second.agent])
        let url = URL(string: "https://example.com/page?q=a%20b#section")!
        let attachment = try repository.importLinkAttachment(url, into: group.id, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(attachment.url, url)
        XCTAssertEqual(attachment.mediaType, "application/x-webloc")
        let bookmark = try Data(contentsOf: repository.attachmentFileURL(attachment))
        let fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: bookmark, format: nil) as? [String: String])
        XCTAssertEqual(fields, ["URL": url.absoluteString])
        XCTAssertEqual(attachment.byteCount, Int64(bookmark.count))
        let sent = try repository.sendAgentMessage(agentID: first.agent.id, conversationID: group.id, body: "Read this", attachmentIDs: [attachment.id])
        let reloaded = WorkspaceRepository(rootURL: root)
        XCTAssertEqual(try reloaded.loadAttachments(conversationID: group.id), [attachment])
        let deliveries = try reloaded.latestMessages(for: second.agent.id, consuming: false, in: group.id, includingRead: true)
        let delivered = try XCTUnwrap(deliveries.first(where: { $0.message.id == sent.id })?.attachments.first)
        XCTAssertEqual(delivered.url, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: delivered.absolutePath))
        XCTAssertNil(try reloaded.inlineImageDataURL(for: delivered))

        // Old attachment records have no URL key and continue to decode as files.
        let file = ConversationAttachment(conversationID: group.id, originalFilename: "a.txt", storedFilename: "a.txt", mediaType: "text/plain", byteCount: 1)
        let encoded = try JSONEncoder().encode(file)
        XCTAssertNil((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["url"])
        XCTAssertNil(try JSONDecoder().decode(ConversationAttachment.self, from: encoded).url)
        let oldDelivery = MessengerAttachment(attachment: file, absolutePath: "/tmp/a.txt")
        XCTAssertNil(try JSONDecoder().decode(MessengerAttachment.self, from: JSONEncoder().encode(oldDelivery)).url)
    }

    func testCLIMixedAttachmentsAndFailedSendCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-url-cli-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Tester")
        let file = root.appendingPathComponent("report with spaces.txt")
        try Data("local file contents".utf8).write(to: file)
        let prefix = ["messenger", "--agent-directory", repository.directory(for: bot.agent).path,
                      "--send", "--conversation", bot.conversation.id.uuidString]
        let result = MessengerCLI.run(arguments: prefix + ["--attach", file.path, "--attach", file.absoluteString,
            "--attach", "http://example.com/a", "--attach", "https://example.com/b#anchor"], environment: [:])
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let attachments = try repository.loadAttachments(conversationID: bot.conversation.id)
        XCTAssertEqual(attachments.count, 4)
        XCTAssertEqual(attachments.filter { $0.url != nil }.count, 2)
        for local in attachments.filter({ $0.url == nil }) {
            XCTAssertEqual(try String(contentsOf: repository.attachmentFileURL(local), encoding: .utf8), "local file contents")
        }
        let onlyLink = MessengerCLI.run(arguments: prefix + ["--attach", "https://example.com/only"], environment: [:])
        XCTAssertEqual(onlyLink.exitCode, 0, onlyLink.standardError)
        let beforeFailure = try repository.loadAttachments(conversationID: bot.conversation.id)
        let failed = MessengerCLI.run(arguments: prefix + ["--attach", "https://example.com/rollback",
            "--attach", root.appendingPathComponent("missing.txt").path], environment: [:])
        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertEqual(try repository.loadAttachments(conversationID: bot.conversation.id), beforeFailure)
        let invalid = MessengerCLI.run(arguments: prefix + ["--attach", "ftp://example.com/a"], environment: [:])
        XCTAssertNotEqual(invalid.exitCode, 0)
        XCTAssertEqual(try repository.loadAttachments(conversationID: bot.conversation.id), beforeFailure)
    }
}
