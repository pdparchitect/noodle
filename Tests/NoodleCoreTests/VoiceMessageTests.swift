import XCTest
@testable import NoodleCore

final class VoiceMessageTests: XCTestCase {
    func testLegacyAttachmentsAndValidation() throws {
        let attachment = ConversationAttachment(conversationID: UUID(), originalFilename: "old.txt",
            storedFilename: "old.txt", mediaType: "text/plain", byteCount: 3)
        let data = try JSONEncoder().encode(attachment)
        XCTAssertNil(try JSONDecoder().decode(ConversationAttachment.self, from: data).voice)
        XCTAssertNil((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["voice"])
        XCTAssertNil(VoiceMessage(transcript: "  ", duration: 1, waveform: [], localeIdentifier: nil).transcript)
        for duration in [0, -1, .infinity, .nan, 661] {
            XCTAssertFalse(VoiceMessage(transcript: nil, duration: duration, waveform: [], localeIdentifier: nil).isValid)
        }
        for samples: [Float] in [[-1], [2], [.nan], Array(repeating: 0, count: 121)] {
            XCTAssertFalse(VoiceMessage(transcript: nil, duration: 1, waveform: samples, localeIdentifier: nil).isValid)
        }
    }

    func testVoiceSurvivesStorageAndReachesAgentWithoutBodyDuplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-voice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Listener")
        let conversation = try XCTUnwrap(repository.loadConversations().first { $0.participantIDs == [bot.agent.id] })
        let source = root.appendingPathComponent("recording.caf")
        try Data([1, 2, 3]).write(to: source)
        let voice = VoiceMessage(transcript: " Please review the draft. ", duration: 2.5,
                                 waveform: [0.1, 0.8, 0.2], localeIdentifier: "en-GB")
        let attachment = try repository.importAttachment(from: source, into: conversation.id, mediaType: "audio/x-caf", voice: voice)
        let message = try repository.sendUserMessage(conversationID: conversation.id, body: VoiceMessage.messageBody, attachmentIDs: [attachment.id])
        let reloaded = WorkspaceRepository(rootURL: root)
        XCTAssertEqual(try reloaded.loadAttachments(conversationID: conversation.id).first?.voice, voice)
        let deliveries = try reloaded.latestMessages(for: bot.agent.id, consuming: false, in: conversation.id, includingRead: true)
        let delivery = try XCTUnwrap(deliveries.first { $0.message.id == message.id })
        XCTAssertEqual(delivery.message.body, "Voice message")
        XCTAssertEqual(delivery.attachments.first?.voice?.transcript, "Please review the draft.")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(delivery.attachments.first?.absolutePath))), Data([1, 2, 3]))
        XCTAssertThrowsError(try repository.importAttachment(from: source, into: conversation.id, mediaType: "text/plain", voice: voice))
        XCTAssertThrowsError(try repository.importAttachment(from: URL(string: "https://example.com")!, into: conversation.id, mediaType: "audio/x-caf", voice: voice))
    }
}
