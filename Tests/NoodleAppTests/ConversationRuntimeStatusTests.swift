import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class ConversationRuntimeStatusTests: XCTestCase {
    func testWorkingWinsOverFailureAndFailureOverReady() {
        XCTAssertEqual(ConversationRuntimeStatus(phases: [.ready, .failed, .working]), .working)
        XCTAssertEqual(ConversationRuntimeStatus(phases: [.ready, .failed]), .failed)
        XCTAssertEqual(ConversationRuntimeStatus(phases: [.ready, .ready]), .ready)
    }

    func testIdleOnlyWhenNoBotCanAnswer() {
        XCTAssertEqual(ConversationRuntimeStatus(phases: []), .idle)
        XCTAssertEqual(ConversationRuntimeStatus(phases: [.offline]), .idle)
        XCTAssertEqual(ConversationRuntimeStatus(phases: [.offline, .starting]), .idle)
    }

    func testOneBotStoppedLeavesTheGroupReady() {
        XCTAssertEqual(ConversationRuntimeStatus(phases: [.ready, .offline]), .ready)
        XCTAssertEqual(ConversationRuntimeStatus(phases: [.ready, .starting]), .ready)
    }

    func testOnlyASuspendedMembersFaceIsGrayInAGroupPicture() throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        var ada = f.a, grace = f.b
        ada.suspendedUntil = AgentRecord.indefinitely
        ada.avatarColorIndex = 0
        grace.avatarColorIndex = 0
        let size: CGFloat = 80
        let renderer = ImageRenderer(content: ConversationAvatar(participants: [ada, grace], isGroup: true, size: size))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        func colourfulness(x: CGFloat, y: CGFloat) throws -> CGFloat {
            let colour = try XCTUnwrap(bitmap.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB))
            let parts = [colour.redComponent, colour.greenComponent, colour.blueComponent]
            return parts.max()! - parts.min()!
        }
        let frames = ConversationAvatar.memberFrames(count: 2, size: size, scale: 1)
        // By the outer edge of each face: clear of the symbol in its middle and of the other face.
        XCTAssertLessThan(try colourfulness(x: frames[0].minX + frames[0].width * 0.14, y: frames[0].midY), 0.03)
        XCTAssertGreaterThan(try colourfulness(x: frames[1].maxX - frames[1].width * 0.14, y: frames[1].midY), 0.1)
    }

    func testAvatarDrawsTheDotInsideARingCutOutOfThePicture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-status-\(UUID())")
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Status Bot")
        let suite = "noodle-status-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(homeDirectory: root,
            applicationsDirectory: root, executableSearchDirectories: [], applicationBundleURL: root), defaults: defaults)
        let store = NoodleStore(repository: repository, runtime: runtime, connectsServices: false)
        addTeardownBlock { @MainActor in
            store.stopMonitoring()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let renderer = ImageRenderer(content: ConversationStatusAvatar(conversation: bot.conversation,
            size: 20, dotSize: 7, ringWidth: 1.5).environment(store))
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        // The dot sits in the bottom trailing corner; the ring left of it shows what is behind.
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 33, y: 33)).alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 24, y: 33)).alphaComponent, 0, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 20, y: 20)).alphaComponent, 1, accuracy: 0.01)
    }
}
