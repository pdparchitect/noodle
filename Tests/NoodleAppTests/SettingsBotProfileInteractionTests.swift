import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class SettingsBotProfileInteractionTests: HiddenViewTests {
    func testProfilesInBothSettingsTabsOpenTheCorrectEditorAndRefreshAfterSave() async throws {
        for heartbeat in [false, true] {
            let f = try fixture()
            let description = "Researches technical questions and turns findings into practical next steps."
            _ = try f.repository.updateAgent(f.a, displayName: f.a.displayName,
                harnessIdentifier: f.a.harnessIdentifier, modelIdentifier: nil, reasoningEffort: nil,
                publicDescription: description, avatarSymbolName: "lightbulb.fill", avatarColorIndex: 2)
            f.store.reload()
            let settings = hostSettings(f, heartbeat: heartbeat)
            let window = try XCTUnwrap(settings.window)
            window.orderFront(nil)

            if heartbeat {
                let heading = try await control("About heartbeats", in: settings)
                press(heading)
                var info: NSView?
                try await wait {
                    info = NSApp.windows.filter { $0.isVisible && $0 !== window && $0.sheetParent == nil }
                        .compactMap(\.contentView).first {
                            self.elements($0).contains { self.labels($0).contains { $0.contains("Heartbeats run only while the bot is idle") } }
                        }
                    return info != nil
                }
                let explanation = try XCTUnwrap(info)
                if let directory = ProcessInfo.processInfo.environment["NOODLE_SETTINGS_PROFILE_SCREENSHOT_DIRECTORY"] {
                    try snapshot(explanation, to: directory, name: "heartbeat-explanation")
                }
                press(heading)
                try await wait { explanation.window?.isVisible != true }
            }

            let profile = try await openProfile("Ada", in: settings)
            _ = try await control(description, in: profile)
            if let directory = ProcessInfo.processInfo.environment["NOODLE_SETTINGS_PROFILE_SCREENSHOT_DIRECTORY"] {
                try snapshot(settings, to: directory, name: heartbeat ? "heartbeat" : "sandbox")
                try snapshot(profile, to: directory, name: "profile")
            }
            let message = try await control("Direct Message", in: profile)
            XCTAssertTrue(enabled(message))
            press(try await control("Edit Bot", in: profile))
            try await wait { !window.sheets.isEmpty }
            XCTAssertFalse(profile.window?.isVisible == true)
            let editor = try XCTUnwrap(window.sheets.first?.contentView)
            let field = try await nameField(in: editor, name: "Ada")
            edit(field, text: "Ada Updated")
            press(try await control("Save", in: editor))
            try await wait { window.sheets.isEmpty && f.store.agents.contains { $0.displayName == "Ada Updated" } }
            XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.a.id }?.displayName, "Ada Updated")
            XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.b.id }?.displayName, "Grace")

            let updated = try await openProfile("Ada Updated", in: settings)
            _ = try await control("Ada Updated", in: updated)
            press(try await control("Close bot profile", in: updated))
            try await wait { updated.window?.isVisible != true }
            let other = try await openProfile("Grace", in: settings)
            _ = try await control("Grace", in: other)
            press(try await control("Close bot profile", in: other))
            try await wait { other.window?.isVisible != true }
            window.close()
        }
    }

    func testMessageFocusesTheMatchingConversationEvenWithHeartbeatsDisabled() async throws {
        let f = try fixture()
        f.runtime.runtime.configureHeartbeats(enabled: false)
        f.store.selectedConversationID = f.directB.id
        let conversation = host(Color.clear.background(ConversationWindowHost(
            registry: f.store.conversationWindows, conversationID: f.directA.id, markRead: { _ in }
        )))
        let conversationWindow = try XCTUnwrap(conversation.window)
        let settings = hostSettings(f, heartbeat: true)
        let settingsWindow = try XCTUnwrap(settings.window)
        settingsWindow.orderFront(nil)
        let heartbeat = try await control("Heartbeat for Ada", in: settings)
        XCTAssertFalse(enabled(heartbeat))

        let profile = try await openProfile("Ada", in: settings)
        XCTAssertFalse(conversationWindow.isVisible)
        press(try await control("Direct Message", in: profile))
        try await wait { conversationWindow.isVisible }
        XCTAssertFalse(profile.window?.isVisible == true)
        XCTAssertEqual(f.store.selectedConversationID, f.directB.id)
        XCTAssertTrue(f.store.messages(for: f.directA).isEmpty)
        XCTAssertTrue(f.runtime.factory.processes.isEmpty, "Opening a profile or chat must not wake the agent")
        settingsWindow.close()
        conversationWindow.close()
    }

    private func hostSettings(_ f: StoreFixture, heartbeat: Bool) -> NSView {
        if heartbeat { return host(HeartbeatsSettingsView().environment(f.store).preferredColorScheme(.dark)) }
        return host(AgentAccessSettingsView().environment(f.store).preferredColorScheme(.dark))
    }

    private func snapshot(_ view: NSView, to directory: String, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func openProfile(_ name: String, in settings: NSView) async throws -> NSView {
        let button = try await control("Show profile for \(name)", in: settings)
        XCTAssertTrue(enabled(button))
        press(button)
        var content: NSView?
        try await wait {
            content = NSApp.windows.filter { $0.isVisible && $0 !== settings.window && $0.sheetParent == nil }
                .compactMap(\.contentView).first { self.hasControl("Close bot profile", in: $0) }
            return content != nil
        }
        return try XCTUnwrap(content)
    }
}
