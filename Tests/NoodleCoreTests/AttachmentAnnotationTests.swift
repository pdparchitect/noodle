import XCTest
@testable import NoodleCore

final class AttachmentAnnotationTests: XCTestCase {
    func testCommentEditsAreRestrictedToUnsentDrafts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-edits-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Reviewer")
        let source = try repository.importAttachment(data: Data("Original source".utf8), originalFilename: "source.txt",
            into: bot.conversation.id, mediaType: "text/plain")
        let note = AttachmentAnnotation(source: source, quote: "Original source", comment: "First comment")
        let draft = try repository.importAttachment(data: Data(note.textRepresentation.utf8), originalFilename: "note.txt",
            into: bot.conversation.id, mediaType: "text/plain", annotation: note)
        var drafts = ConversationDrafts()
        XCTAssertFalse(drafts.canEditAnnotation(draft, messages: []), "Only composer drafts offer editing")
        drafts.restoreAnnotations([draft], messages: [], conversationID: bot.conversation.id)
        XCTAssertTrue(drafts.canEditAnnotation(draft, messages: []))
        let editedNote = note.replacingComment(" Revised comment ")
        let edited = try repository.reviseAnnotationComment(draft, comment: " Revised comment ", content: Data(editedNote.textRepresentation.utf8))
        XCTAssertEqual(edited.id, draft.id)
        XCTAssertEqual(edited.annotation, editedNote)
        XCTAssertEqual(try String(contentsOf: repository.attachmentFileURL(edited), encoding: .utf8), editedNote.textRepresentation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.attachmentFileURL(draft).path))
        XCTAssertThrowsError(try repository.reviseAnnotationComment(draft, comment: "Stale edit", content: Data()))
        XCTAssertThrowsError(try repository.reviseAnnotationComment(edited, comment: "  ", content: Data()))
        XCTAssertTrue(try repository.latestMessages(for: bot.agent.id, consuming: false).isEmpty)
        let sent = try repository.sendUserMessage(conversationID: bot.conversation.id, body: "Review this", attachmentIDs: [edited.id])
        _ = try repository.latestMessages(for: bot.agent.id, consuming: true)
        XCTAssertFalse(drafts.canEditAnnotation(edited, messages: [sent]), "Submission revokes editing even before stale draft state clears")
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: repository.attachmentsDirectory(conversationID: bot.conversation.id).path).sorted()
        let revisionNote = editedNote.replacingComment("Another revision")
        XCTAssertThrowsError(try repository.reviseAnnotationComment(edited, comment: revisionNote.comment, content: Data(revisionNote.textRepresentation.utf8)),
            "An editor opened before submission cannot create a revision afterwards")
        XCTAssertThrowsError(try repository.reviseAnnotationComment(edited, comment: editedNote.comment, content: Data(editedNote.textRepresentation.utf8)),
            "Even an unchanged comment cannot be saved after submission")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repository.attachmentsDirectory(conversationID: bot.conversation.id).path).sorted(), filesBefore)
        XCTAssertEqual(try repository.loadAttachments(conversationID: bot.conversation.id).first { $0.id == edited.id }, edited)
        XCTAssertEqual(try String(contentsOf: repository.attachmentFileURL(edited), encoding: .utf8), editedNote.textRepresentation)
        let history = try repository.latestMessages(for: bot.agent.id, consuming: false, in: bot.conversation.id, includingRead: true)
        XCTAssertEqual(history.first?.attachments.first?.annotation, editedNote)
        XCTAssertTrue(try repository.latestMessages(for: bot.agent.id, consuming: false).isEmpty, "Rejected edits must not notify or redeliver")
        drafts.clear(bot.conversation.id)
        drafts.restoreAnnotations(try repository.loadAttachments(conversationID: bot.conversation.id), messages: [sent], conversationID: bot.conversation.id)
        XCTAssertTrue(drafts[bot.conversation.id].attachments.isEmpty, "No revised draft is created")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP438DwHwAGgAJ/EEwb4QAAAABJRU5ErkJggg==")!
        let visual = AttachmentAnnotation(source: source, comment: "Visual comment", region: .init(x: 0, y: 0, width: 1, height: 1))
        let image = try repository.importAttachment(data: png, originalFilename: "note.png", into: bot.conversation.id, mediaType: "image/png", annotation: visual)
        let updatedImage = try repository.reviseAnnotationComment(image, comment: "New visual comment", content: png)
        XCTAssertEqual(updatedImage.annotation?.comment, "New visual comment")
        XCTAssertEqual(updatedImage.annotation?.region, visual.region)
        XCTAssertEqual(try Data(contentsOf: repository.attachmentFileURL(updatedImage)), png)
        _ = try repository.sendUserMessage(conversationID: bot.conversation.id, body: "Review image", attachmentIDs: [updatedImage.id])
        XCTAssertThrowsError(try repository.reviseAnnotationComment(updatedImage, comment: "Changed after sending", content: png))
        XCTAssertEqual(try Data(contentsOf: repository.attachmentFileURL(updatedImage)), png)
        XCTAssertEqual(try repository.loadAttachments(conversationID: bot.conversation.id).first { $0.id == updatedImage.id }, updatedImage)
    }

    func testSubmittedAnnotationsAreReadOnlyBeforeDeliveryAndForEveryAuthor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-submitted-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Reviewer")
        let source = try repository.importAttachment(data: Data("Source".utf8), originalFilename: "source.txt",
            into: bot.conversation.id, mediaType: "text/plain")
        for author: MessageAuthor in [.user, .agent(bot.agent.id)] {
            let note = AttachmentAnnotation(source: source, comment: "Submitted feedback")
            let file = try repository.importAttachment(data: Data(note.textRepresentation.utf8), originalFilename: "note.txt",
                into: bot.conversation.id, mediaType: "text/plain", annotation: note)
            var drafts = ConversationDrafts()
            drafts[bot.conversation.id].attachments = [file]
            let message = ChatMessage(conversationID: bot.conversation.id, author: author, body: "Submitted",
                delivery: .queued, attachmentIDs: [file.id])
            try repository.append(message)
            XCTAssertFalse(drafts.canEditAnnotation(file, messages: [message]))
            let update = note.replacingComment("Changed")
            XCTAssertThrowsError(try repository.reviseAnnotationComment(file, comment: update.comment, content: Data(update.textRepresentation.utf8)))
            XCTAssertEqual(try Data(contentsOf: repository.attachmentFileURL(file)), Data(note.textRepresentation.utf8))
        }
    }

    func testPersistenceDraftRecoveryAndDeliveryToGroup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let first = try repository.createAgent(named: "First")
        let second = try repository.createAgent(named: "Second")
        let group = try repository.createGroup(named: "Review", participantIDs: [first.agent.id, second.agent.id],
            existingAgents: [first.agent, second.agent])
        let source = try repository.importAttachment(data: Data("Original text".utf8), originalFilename: "source.txt",
            into: group.id, mediaType: "text/plain", now: Date(timeIntervalSince1970: 1_700_000_000))
        let note = AttachmentAnnotation(source: source, quote: "Original text", comment: " Clarify this ")
        let file = try repository.importAttachment(data: Data(note.textRepresentation.utf8),
            originalFilename: "Annotation.txt", into: group.id, mediaType: "text/plain", now: Date(timeIntervalSince1970: 1_700_000_001), annotation: note)
        let reloaded = WorkspaceRepository(rootURL: root)
        let saved = try reloaded.loadAttachments(conversationID: group.id)
        XCTAssertEqual(saved.first(where: { $0.id == file.id })?.annotation, note)
        XCTAssertEqual(note.comment, "Clarify this")
        XCTAssertEqual(try Data(contentsOf: repository.attachmentFileURL(source)), Data("Original text".utf8))

        var drafts = ConversationDrafts()
        drafts[group.id].text = "Existing draft"
        drafts.restoreAnnotations(saved, messages: [], conversationID: group.id)
        drafts.restoreAnnotations(saved, messages: [], conversationID: group.id)
        XCTAssertEqual(drafts[group.id].attachments, [file])
        XCTAssertEqual(drafts[group.id].text, "Existing draft")
        XCTAssertTrue(try repository.latestMessages(for: first.agent.id, consuming: false, in: group.id).isEmpty,
                      "Saving alone must not deliver feedback")

        let message = try repository.sendUserMessage(conversationID: group.id, body: "Review this", attachmentIDs: [file.id])
        for agent in [first.agent, second.agent] {
            let delivery = try XCTUnwrap(repository.latestMessages(for: agent.id, consuming: false, in: group.id)
                .first(where: { $0.message.id == message.id }))
            XCTAssertEqual(delivery.attachments.first?.annotation, note)
            XCTAssertEqual(delivery.attachments.first?.mediaType, "text/plain")
            let cli = MessengerCLI.runDirect(arguments: ["messenger", "--list-messages", "--conversation", group.id.uuidString],
                environment: ["NOODLE_WORKSPACE": repository.directory(for: agent).path])
            XCTAssertEqual(cli.exitCode, 0, cli.standardError)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cli.standardOutput.utf8)) as? [[String: Any]])
            let files = json.compactMap { $0["attachments"] as? [[String: Any]] }.flatMap { $0 }
            let metadata = try XCTUnwrap(files.first?["annotation"] as? [String: Any])
            XCTAssertEqual(metadata["version"] as? Int, 2)
            XCTAssertEqual(metadata["comment"] as? String, note.comment)
            XCTAssertEqual(metadata["quote"] as? String, note.quote)
            let path = try XCTUnwrap(files.first?["absolutePath"] as? String)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), note.textRepresentation)
        }
        var restarted = ConversationDrafts()
        restarted.restoreAnnotations(saved, messages: [message], conversationID: group.id)
        XCTAssertTrue(restarted[group.id].attachments.isEmpty, "Sent annotations must not reappear in drafts")
        try repository.removeAttachment(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.attachmentFileURL(file).path))
        XCTAssertEqual(try repository.loadAttachments(conversationID: group.id), [source])
    }

    func testInvalidAndCrossConversationReferencesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-validation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let first = try repository.createAgent(named: "First")
        let second = try repository.createAgent(named: "Second")
        let source = try repository.importAttachment(data: Data("text".utf8), originalFilename: "a.txt",
            into: first.conversation.id, mediaType: "text/plain")
        let note = AttachmentAnnotation(source: source, comment: "Feedback")
        XCTAssertThrowsError(try repository.importAttachment(data: Data(note.textRepresentation.utf8), originalFilename: "note.txt",
            into: second.conversation.id, mediaType: "text/plain", annotation: note))
        for (data, type) in [(Data("Unrelated content".utf8), "text/plain"), (Data("%PDF-1.7".utf8), "application/pdf")] {
            XCTAssertThrowsError(try repository.importAttachment(data: data, originalFilename: "note.txt",
                into: first.conversation.id, mediaType: type, annotation: note))
        }
        let visual = AttachmentAnnotation(source: source, comment: "Image feedback", region: .init(x: 0, y: 0, width: 1, height: 1))
        XCTAssertThrowsError(try repository.importAttachment(data: Data([137, 80, 78, 71, 13, 10, 26, 10]),
            originalFilename: "note.png", into: first.conversation.id, mediaType: "image/png", annotation: visual))
        for region in [AttachmentAnnotation.Region(x: -0.1, y: 0, width: 0.2, height: 0.2),
                       .init(x: 0.9, y: 0, width: 0.2, height: 0.2), .init(x: 0, y: 0, width: .nan, height: 1)] {
            XCTAssertFalse(AttachmentAnnotation(source: source, comment: "Feedback", region: region).isValid)
        }
        XCTAssertFalse(AttachmentAnnotation(source: source, comment: " \n ").isValid)
        XCTAssertFalse(AttachmentAnnotation(source: source, quote: "text", comment: "Feedback",
            region: .init(x: 0, y: 0, width: 1, height: 1)).isValid)
        XCTAssertTrue(try repository.loadAttachments(conversationID: second.conversation.id).isEmpty)
    }

    func testOldAttachmentsRemainCompatibleAndRegionRoundTrips() throws {
        let source = ConversationAttachment(conversationID: UUID(), originalFilename: "source.png",
            storedFilename: "source.png", mediaType: "image/png", byteCount: 1)
        let oldData = try JSONEncoder().encode(source)
        XCTAssertNil(try JSONDecoder().decode(ConversationAttachment.self, from: oldData).annotation)
        let oldDelivery = MessengerAttachment(attachment: source, absolutePath: "/fixture/source.png")
        XCTAssertNil(try JSONDecoder().decode(MessengerAttachment.self, from: JSONEncoder().encode(oldDelivery)).annotation)
        let note = AttachmentAnnotation(source: source, comment: "Move this",
            region: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertEqual(try JSONDecoder().decode(AttachmentAnnotation.self, from: JSONEncoder().encode(note)), note)
        let legacy = AttachmentAnnotation(source: source, comment: "Older feedback", version: 1)
        let decoded = try JSONDecoder().decode(AttachmentAnnotation.self, from: JSONEncoder().encode(legacy))
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.mediaType, "application/pdf")
        XCTAssertEqual(decoded.comment, "Older feedback")
    }

    func testVisualAnnotationUsesImageDeliveryAndCLIMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-image-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Image reviewer")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP438DwHwAGgAJ/EEwb4QAAAABJRU5ErkJggg=="))
        let source = try repository.importAttachment(data: png, originalFilename: "source.png", into: bot.conversation.id, mediaType: "image/png")
        let note = AttachmentAnnotation(source: source, comment: "Use a warmer colour", region: .init(x: 0, y: 0, width: 1, height: 1))
        let file = try repository.importAttachment(data: png, originalFilename: "note.png", into: bot.conversation.id,
            mediaType: note.mediaType, annotation: note)
        let metadataURL = repository.attachmentFileURL(file).deletingLastPathComponent()
            .appendingPathComponent("\(file.id.uuidString.lowercased()).json")
        var diskRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        diskRecord["mediaType"] = "application/octet-stream"
        try JSONSerialization.data(withJSONObject: diskRecord).write(to: metadataURL)
        let repaired = try XCTUnwrap(repository.loadAttachments(conversationID: bot.conversation.id).first { $0.id == file.id })
        XCTAssertEqual(repaired.mediaType, "image/png")
        XCTAssertEqual(repaired.annotation, note, "Image type repair must preserve annotation metadata")
        _ = try repository.sendUserMessage(conversationID: bot.conversation.id, body: "Review", attachmentIDs: [file.id])
        let cli = MessengerCLI.runDirect(arguments: ["messenger", "--get-latest", "--peek", "--inline-images"],
            environment: ["NOODLE_WORKSPACE": repository.directory(for: bot.agent).path])
        XCTAssertEqual(cli.exitCode, 0, cli.standardError)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cli.standardOutput.utf8)) as? [String: Any])
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?["mediaType"] as? String, "image/png")
        XCTAssertEqual(images.first?["dataURL"] as? String, "data:image/png;base64,\(png.base64EncodedString())")
        let deliveries = try XCTUnwrap(json["deliveries"] as? [[String: Any]])
        let files = deliveries.compactMap { $0["attachments"] as? [[String: Any]] }.flatMap { $0 }
        let metadata = try XCTUnwrap(files.first?["annotation"] as? [String: Any])
        XCTAssertEqual(metadata["comment"] as? String, note.comment)
        XCTAssertEqual(metadata["sourceAttachmentID"] as? String, source.id.uuidString)
        XCTAssertNotNil(metadata["region"])
    }
}
