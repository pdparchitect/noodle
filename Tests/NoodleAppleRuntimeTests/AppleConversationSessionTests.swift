import XCTest
import FoundationModels
@testable import NoodleAppleRuntime

final class AppleConversationSessionTests: XCTestCase {
    func testImageReceiptPersistsTextReferenceAndFinalResponse() throws {
        #if canImport(FoundationModels, _version: 2)
        guard #available(macOS 27, *) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-image-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Apple27LiveTests.writeSquare(to: file)
        let prompt = Transcript.Entry.prompt(.init(segments: [
            .text(.init(content: "What color?")),
            .attachment(.init(content: .image(.init(imageURL: file)), label: "square.png"))
        ]))
        let response = Transcript.Entry.response(.init(assetIDs: ["synthetic"], segments: [.text(.init(content: "Red"))]))
        let stored = AppleConversationSession.persistable(Transcript(entries: [prompt, response]))
        let data = try JSONEncoder().encode(stored)
        let restored = try JSONDecoder().decode(Transcript.self, from: data)
        XCTAssertEqual(restored.last, response)
        XCTAssertTrue(restored.first?.description.contains("square.png") == true)
        guard case .prompt(let saved) = restored.first else { return XCTFail("Missing prompt") }
        XCTAssertTrue(saved.segments.allSatisfy { if case .text = $0 { return true }; return false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        #endif
    }

    func testCachePreservesNativeMetadataAndCompletedDelivery() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Foundation Models requires macOS 26") }
        let prompt = Transcript.Entry.prompt(.init(id: "user-turn", segments: [.text(.init(content: "Remember saffron"))]))
        let response = Transcript.Entry.response(.init(id: "native-response", assetIDs: ["original-model-asset"],
                                                       segments: [.text(.init(content: "I'll remember saffron."))]))
        let id = UUID()
        let original = AppleConversationSession(transcript: Transcript(entries: [prompt, response]), messageIDs: [id], reply: "I'll remember saffron.")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("apple-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let conversation = UUID()
        try original.save(in: workspace, conversationID: conversation)
        let restored = try JSONDecoder().decode(AppleConversationSession.self,
            from: Data(contentsOf: AppleConversationSession.file(in: workspace, conversationID: conversation)))
        XCTAssertEqual(restored.recentEntries(), [prompt, response])
        XCTAssertTrue(restored.recentEntries(reservingPromptBytes: 6_000).isEmpty)
        XCTAssertEqual(restored.messageIDs, [id])
        XCTAssertEqual(restored.reply, original.reply)
    }

    func testTrimmingKeepsToolExchangesTogetherAndDropsOldInstructions() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Foundation Models requires macOS 26") }
        let instructions = Transcript.Entry.instructions(.init(segments: [.text(.init(content: "Obsolete identity"))], toolDefinitions: []))
        let older: [Transcript.Entry] = [
            .prompt(.init(segments: [.text(.init(content: "Read a very large file"))])),
            .toolCalls(.init([.init(id: "old-call", toolName: "read_file", arguments: try GeneratedContent(json: "{}"))])),
            .toolOutput(.init(id: "old-call", toolName: "read_file", segments: [.text(.init(content: String(repeating: "a", count: 6_000)))])),
            .response(.init(assetIDs: ["asset"], segments: [.text(.init(content: "Read it."))]))
        ]
        let recent: [Transcript.Entry] = [
            .prompt(.init(segments: [.text(.init(content: "Read the small file"))])),
            .toolCalls(.init([.init(id: "new-call", toolName: "read_file", arguments: try GeneratedContent(json: "{}"))])),
            .toolOutput(.init(id: "new-call", toolName: "read_file", segments: [.text(.init(content: "saffron"))])),
            .response(.init(assetIDs: ["asset"], segments: [.text(.init(content: "saffron"))]))
        ]
        let session = AppleConversationSession(transcript: Transcript(entries: [instructions] + older + recent), messageIDs: [UUID()], reply: "saffron")
        XCTAssertEqual(session.recentEntries(), recent)
    }
}
