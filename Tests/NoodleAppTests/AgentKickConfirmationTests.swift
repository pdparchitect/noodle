import AppKit
import Observation
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class AgentKickConfirmationTests: XCTestCase {
    func testNativeConfirmationCancelsWithoutChangesAndRecoversOnlyAfterApproval() async throws {
        let fixture = try RuntimeCoordinatorFixture()
        defer { fixture.cleanUp() }
        let agent = try fixture.agent("BB-464", harness: .grokBuild)
        let store = NoodleStore(repository: fixture.repository, runtime: fixture.runtime, connectsServices: false)
        defer { store.stopMonitoring() }
        let process = try fixture.start(agent)
        let stateURL = fixture.repository.storage(for: agent.id).sessionState(provider: .grokBuild, extendedAccess: false)
        let sessionID = UUID().uuidString
        try ACPSessionState(sessionID: sessionID).save(to: stateURL)
        process.transition(.failed, failure: .missingSession(sessionID))
        let original = try Data(contentsOf: stateURL)
        let model = KickDialogFixtureModel()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 600, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Noodle recovery confirmation test"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: KickDialogFixture(model: model).environment(store))
        window.orderFront(nil)
        defer {
            for sheet in window.sheets { window.endSheet(sheet) }
            window.close()
            window.contentView = nil
        }
        try await Task.sleep(for: .milliseconds(100))

        for confirm in [false, true] {
            model.request = try XCTUnwrap(fixture.runtime.kick(agent: agent, repository: fixture.repository))
            let sheet = try await waitForSheet(window)
            let buttons = descendants(sheet.contentView).compactMap { $0 as? NSButton }
            XCTAssertTrue(buttons.contains { $0.title == "Recover Bot" })
            XCTAssertTrue(buttons.contains { $0.title == "Cancel" })
            let text = descendants(sheet.contentView).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
            XCTAssertTrue(text.contains("Recover BB-464?"), text)
            XCTAssertTrue(text.contains("may be lost"), text)
            if let directory = ProcessInfo.processInfo.environment["NOODLE_KICK_SCREENSHOT_DIRECTORY"], !confirm,
               let view = sheet.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("kick-confirmation.png"))
            }
            let button = try XCTUnwrap(buttons.first { $0.title == (confirm ? "Recover Bot" : "Cancel") })
            button.performClick(nil)
            for _ in 0..<100 where !window.sheets.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(window.sheets.isEmpty)
            if !confirm {
                XCTAssertEqual(try Data(contentsOf: stateURL), original)
                XCTAssertEqual(process.stops, 0)
            }
        }
        let recovered = try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: stateURL))
        XCTAssertEqual(recovered.previousSessionIDs, [sessionID])
        XCTAssertNil(recovered.sessionID)
        XCTAssertTrue(recovered.needsHistoryRecovery)
        XCTAssertEqual(fixture.factory.processes.count, 2)
    }

    private func waitForSheet(_ window: NSWindow) async throws -> NSWindow {
        for _ in 0..<100 {
            if let sheet = window.sheets.first { return sheet }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(window.sheets.first, "Recovery confirmation did not appear")
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }
}

@MainActor @Observable private final class KickDialogFixtureModel {
    var request: AgentKickRequest?
}

private struct KickDialogFixture: View {
    @Bindable var model: KickDialogFixtureModel
    var body: some View {
        Text("Recovery confirmation fixture")
            .frame(width: 600, height: 420)
            .modifier(AgentKickConfirmation(request: $model.request))
    }
}
