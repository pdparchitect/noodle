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

    func testAnythingShortOfAllReadyIsIdle() {
        XCTAssertEqual(ConversationRuntimeStatus(phases: []), .idle)
        XCTAssertEqual(ConversationRuntimeStatus(phases: [.ready, .starting]), .idle)
        XCTAssertEqual(ConversationRuntimeStatus(phases: [.offline]), .idle)
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
