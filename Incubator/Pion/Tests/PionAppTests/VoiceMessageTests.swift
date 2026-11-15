import NoodleCore
import XCTest

/// Pion sends voice messages as Noodle does: the recording as an audio attachment with its transcript, and any
/// files waiting in the composer with it; the agents and a call in progress hear what was said.
@MainActor final class VoiceMessageTests: XCTestCase {
    func testAVoiceMessageIsSentWithItsRecordingAndTheWaitingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionVoice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let agent = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: agent))
        let audio = root.appendingPathComponent("take.caf")
        try Data(repeating: 1, count: 2_048).write(to: audio)
        var heard: [(UUID, String, [String])] = []
        model.onSent = { heard.append(($0, $1, $2)) }

        try model.sendVoiceMessage(from: audio, voice: VoiceMessage(transcript: "Check the sign-in logs.", duration: 2,
                                                                     waveform: [0.2, 0.5], localeIdentifier: "en_GB"),
                                   to: direct.id)

        let message = try XCTUnwrap(model.messages(in: direct.id).last)
        XCTAssertEqual(message.author, .user)
        XCTAssertEqual(message.body, VoiceMessage.messageBody)
        let files = (message.attachmentIDs ?? []).compactMap { model.attachments[direct.id]?[$0] }
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.voice?.transcript, "Check the sign-in logs.")
        XCTAssertEqual(heard.first?.1, "Check the sign-in logs.")
    }
}
