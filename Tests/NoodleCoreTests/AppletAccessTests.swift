import AppletBridge
import XCTest

@testable import NoodleCore

final class AppletAccessTests: XCTestCase {
    func testLocalInstructionsAndAttachmentsKeepTheirEnvironment() throws {
        let skill = AppletGuidance.instructions(for: .development)
        XCTAssertTrue(skill.contains("Name.noodlet-dev"))
        XCTAssertTrue(skill.contains("noodlet-dev://UUID"))
        XCTAssertTrue(skill.contains("Noodle Applet Dev"))
        XCTAssertTrue(skill.contains("`noodlet.json`"))
        XCTAssertFalse(skill.contains("Name.noodlet`"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try repository.prepare()
        let conversation = try repository.createAgent(named: "Environment").conversation
        for build in AppletBuildIdentity.allCases {
            let url = NoodletLink.url(for: UUID(), build: build)
            XCTAssertEqual(try AttachmentSource.resolve(url.absoluteString, relativeTo: root), url)
            let attachment = try repository.importLinkAttachment(url, into: conversation.id)
            XCTAssertEqual(attachment.url, url)
            XCTAssertTrue(try repository.loadAttachments(conversationID: conversation.id).contains { $0.url == url })
        }
    }

    /// A game keeps itself smooth on a phone or TV by lowering its own resolution, and reads
    /// devicePixelRatio again on resize, since it changes when the game moves to a TV.
    func testGamesAreToldToReadThePixelRatioAgainOnResize() {
        let skill = AppletGuidance.instructions(for: .production)
        XCTAssertTrue(skill.contains("devicePixelRatio"))
        XCTAssertTrue(skill.contains("resize"))
    }

    /// Every command a bot can run is described; what Noodle and Noodle Hub ask for people is not a bot's.
    func testEveryToolCommandIsDescribed() {
        for command in AppletGuidance.toolOperations {
            XCTAssertFalse(AppletGuidance.operation(command).isEmpty, command.rawValue)
        }
        for command in AppletOperation.allCases where command.isAppOnly || [.show, .artifact].contains(command) {
            XCTAssertFalse(AppletGuidance.toolOperations.contains(command), command.rawValue)
        }
    }
}
