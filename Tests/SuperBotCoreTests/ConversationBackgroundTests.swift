import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SuperBotCore

final class ConversationBackgroundTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("superbot-background-tests-\(UUID())")
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testExistingConversationDefaultsWithoutMigration() throws {
        let bot = try repository.createAgent(named: "Bot")
        XCTAssertTrue(try repository.loadBackground(conversationID: bot.conversation.id).isDefault)
    }

    func testBotAndGroupBackgroundsAreIndependentAndSurviveReload() throws {
        let first = try repository.createAgent(named: "First")
        let second = try repository.createAgent(named: "Second")
        let group = try repository.createGroup(named: "Team", participantIDs: [first.agent.id, second.agent.id], existingAgents: [first.agent, second.agent])
        let metadataURL = repository.conversationDirectory(id: group.id).appendingPathComponent("conversation.json")
        let originalMetadata = try Data(contentsOf: metadataURL)
        try repository.setBackground(conversationID: first.conversation.id, preset: .ocean)
        try repository.setBackground(conversationID: group.id, preset: .sunset)
        let reloaded = WorkspaceRepository(rootURL: root)
        XCTAssertEqual(try reloaded.loadBackground(conversationID: first.conversation.id).preset, .ocean)
        XCTAssertEqual(try reloaded.loadBackground(conversationID: group.id).preset, .sunset)
        XCTAssertTrue(try reloaded.loadBackground(conversationID: second.conversation.id).isDefault)
        XCTAssertEqual(try Data(contentsOf: metadataURL), originalMetadata, "Appearance must not reorder or modify conversation metadata")
        XCTAssertTrue(try reloaded.latestMessages(for: first.agent.id).isEmpty, "Backgrounds are not messages to agents")
    }

    func testImageIsResizedPersistedAndRemovedWhenReset() throws {
        let bot = try repository.createAgent(named: "Bot")
        let background = try repository.setBackground(conversationID: bot.conversation.id, imageData: fixtureImage())
        let url = try XCTUnwrap(repository.backgroundImageURL(background, conversationID: bot.conversation.id))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int), 2560)
        XCTAssertEqual(try repository.loadBackground(conversationID: bot.conversation.id), background)
        try repository.setBackground(conversationID: bot.conversation.id, preset: nil)
        XCTAssertTrue(try repository.loadBackground(conversationID: bot.conversation.id).isDefault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReplacingImageCleansOnlyPreviousManagedImage() throws {
        let bot = try repository.createAgent(named: "Bot")
        let first = try repository.setBackground(conversationID: bot.conversation.id, imageData: fixtureImage())
        let firstURL = try XCTUnwrap(repository.backgroundImageURL(first, conversationID: bot.conversation.id))
        let second = try repository.setBackground(conversationID: bot.conversation.id, imageData: fixtureImage())
        let secondURL = try XCTUnwrap(repository.backgroundImageURL(second, conversationID: bot.conversation.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testInvalidImageDoesNotReplaceExistingBackground() throws {
        let bot = try repository.createAgent(named: "Bot")
        try repository.setBackground(conversationID: bot.conversation.id, preset: .forest)
        XCTAssertThrowsError(try repository.setBackground(conversationID: bot.conversation.id, imageData: Data("not an image".utf8)))
        XCTAssertEqual(try repository.loadBackground(conversationID: bot.conversation.id).preset, .forest)
        XCTAssertThrowsError(try repository.setBackground(conversationID: UUID(), preset: .dusk))
    }

    func testBackgroundImagePathsCannotEscapeConversation() {
        for name in ["../secret.jpg", "/tmp/secret.jpg", "ordinary.jpg", "../../\(UUID()).jpg"] {
            XCTAssertNil(repository.backgroundImageURL(ConversationBackground(imageFilename: name), conversationID: UUID()))
        }
    }

    private func fixtureImage() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3000, height: 10, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
