import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntime
@testable import NoodleRuntimeSettings

@MainActor final class BotsSettingsInteractionTests: HiddenViewTests {
    func testEachBotRowHasItsHeartbeatAndAccessSwitches() async throws {
        let f = try fixture()
        let settings = host(BotsSettingsView(store: f.store).environment(f.store))
        _ = try await control("Wake idle agents", in: settings)
        for name in ["Ada", "Grace"] {
            _ = try await control("Show profile for \(name)", in: settings)
            _ = try await control("Heartbeat for \(name)", in: settings)
            _ = try await control("\(name), unrestricted access", in: settings)
            _ = try await control("\(name), account apps", in: settings)
        }

        f.runtime.runtime.configureHeartbeats(enabled: false)
        let heartbeat = try await control("Heartbeat for Ada", in: settings)
        try await wait { !self.enabled(heartbeat) }
        let access = try await control("Ada, unrestricted access", in: settings)
        let apps = try await control("Ada, account apps", in: settings)
        XCTAssertTrue(enabled(access)); XCTAssertTrue(enabled(apps))
    }

    func testArchivedSwitchArchivesABotAndLocksItsOtherSwitches() async throws {
        let f = try fixture()
        let settings = host(BotsSettingsView(store: f.store).environment(f.store))
        try await flip("Ada, archived", in: settings)
        try await wait { f.store.agents.first { $0.id == f.a.id }?.archivedAt != nil }
        XCTAssertEqual(f.runtime.runtime.archivedAgentIDs, [f.a.id])
        for name in ["Heartbeat for Ada", "Ada, unrestricted access", "Ada, account apps"] {
            let control = try await control(name, in: settings)
            try await wait { !self.enabled(control) }
        }
        let grace = try await control("Grace, unrestricted access", in: settings)
        XCTAssertTrue(enabled(grace))

        try await flip("Ada, archived", in: settings)
        try await wait { f.store.agents.first { $0.id == f.a.id }?.archivedAt == nil }
        let heartbeat = try await control("Heartbeat for Ada", in: settings)
        try await wait { self.enabled(heartbeat) }
    }

    func testGroupsTabArchivesAndRestoresAGroup() async throws {
        let f = try fixture(), group = try f.group()
        let settings = host(GroupsSettingsView().environment(f.store))
        _ = try await control("Show profile for Project", in: settings)
        try await flip("Project, archived", in: settings)
        try await wait { f.store.isArchived(group) }
        XCTAssertTrue(f.store.groupConversations.isEmpty)
        try await flip("Project, archived", in: settings)
        try await wait { !f.store.isArchived(group) }
        XCTAssertEqual(f.store.groupConversations.map(\.id), [group.id])
    }

    func testManyGroupsScrollInsteadOfGrowingTheTab() async throws {
        let f = try fixture()
        for index in 1...20 { _ = try f.group(name: "Group \(index)") }
        let settings = host(GroupsSettingsView().environment(f.store).frame(width: 680))
        _ = try await control("Group 20, archived", in: settings)
        XCTAssertLessThan(settings.fittingSize.height, 500)
    }

    func testAnArchivedChatShowsWhyInADisabledComposer() async throws {
        let f = try fixture()
        XCTAssertTrue(f.store.setArchived(true, agentID: f.a.id))
        let chat = host(ChatView(conversation: f.directA, attachmentPreview: AttachmentPreviewController()).environment(f.store))
        var editor: ComposerTextView?
        try await wait {
            editor = self.elements(chat).compactMap { $0 as? ComposerTextView }.first
            return editor != nil
        }
        let composer = try XCTUnwrap(editor)
        XCTAssertFalse(composer.isEditable)
        XCTAssertEqual(composer.placeholder, "Ada is archived")

        XCTAssertTrue(f.store.setArchived(false, agentID: f.a.id))
        try await wait { composer.isEditable && composer.placeholder == "Message Ada" }
    }

    func testAppsDefaultsOffAndTogglesIndependentlyWithClickableExplanation() async throws {
        let f = try fixture()
        let settings = host(BotsSettingsView(store: f.store).environment(f.store).preferredColorScheme(.dark))
        let window = try XCTUnwrap(settings.window)
        window.setContentSize(.init(width: 680, height: 420))
        window.orderFront(nil)
        let apps = try await control("Ada, account apps", in: settings)
        let access = try await control("Ada, unrestricted access", in: settings)
        XCTAssertEqual(attribute(apps, .value) as? Int, 0)
        XCTAssertEqual(attribute(access, .value) as? Int, 0)
        _ = try await control("restricted", in: settings)
        try snapshot(settings, name: "sandbox-defaults")

        try await flip("Ada, account apps", in: settings)
        try await confirm("Allow Apps for Ada?", with: "Allow Apps", in: window)
        try await wait { f.runtime.runtime.accessConfiguration.appsEnabled(for: f.a) && !f.runtime.runtime.changingAccess.contains(f.a.id) }
        XCTAssertFalse(f.runtime.runtime.accessConfiguration.isExtended(for: f.a))
        XCTAssertTrue(try XCTUnwrap(f.runtime.factory.processes.last).launch.appsEnabled)
        _ = try await control("apps", in: settings)
        _ = try await control("·", in: settings)
        try snapshot(settings, name: "sandbox-restricted-apps")

        try await flip("Ada, unrestricted access", in: settings)
        try await confirm("Allow Unrestricted Access for Ada?", with: "Allow Unrestricted Access", in: window)
        try await wait { f.runtime.runtime.accessConfiguration.isExtended(for: f.a) && !f.runtime.runtime.changingAccess.contains(f.a.id) }
        _ = try await control("unrestricted", in: settings)
        XCTAssertTrue(f.runtime.runtime.accessConfiguration.appsEnabled(for: f.a))
        try snapshot(settings, name: "sandbox-apps")

        for (label, content, name) in [
            ("About unrestricted access", "macOS and tool permissions still apply", "unrestricted-explanation"),
            ("About account apps", "ChatGPT or Claude.ai", "apps-explanation")
        ] {
            let heading = try XCTUnwrap(elements(settings).first {
                attribute($0, .description) as? String == label
            })
            press(heading)
            var popover: NSView?
            try await wait {
                popover = NSApp.windows.filter { $0.isVisible && $0 !== window && $0.sheetParent == nil }
                    .compactMap(\.contentView).first {
                        self.elements($0).contains { self.labels($0).contains { $0.contains(content) } }
                    }
                return popover != nil
            }
            let explanation = try XCTUnwrap(popover)
            XCTAssertTrue(elements(explanation).contains { labels($0).contains { $0.contains("Off by default") } })
            try snapshot(explanation, name: name)
            press(heading)
            try await wait { explanation.window?.isVisible != true }
        }
        window.close()
    }

    func testTurningAccessOnAsksFirstAndTurningItOffDoesNot() async throws {
        let f = try fixture()
        let settings = host(BotsSettingsView(store: f.store).environment(f.store))
        let window = try XCTUnwrap(settings.window)
        let configuration = { f.runtime.runtime.accessConfiguration }
        let settled = { !f.runtime.runtime.changingAccess.contains(f.a.id) }
        for (name, title, allow, isOn) in [
            ("Ada, unrestricted access", "Allow Unrestricted Access for Ada?", "Allow Unrestricted Access", { configuration().isExtended(for: f.a) }),
            ("Ada, account apps", "Allow Apps for Ada?", "Allow Apps", { configuration().appsEnabled(for: f.a) })
        ] {
            try await flip(name, in: settings)
            try await confirm(title, with: "Cancel", in: window)
            XCTAssertFalse(isOn(), "Cancel must leave \(name) off")
            let cancelled = try await control(name, in: settings)
            try await wait { self.attribute(cancelled, .value) as? Int == 0 }

            try await flip(name, in: settings)
            XCTAssertFalse(isOn(), "\(name) must stay off until it is confirmed")
            try await confirm(title, with: allow, in: window)
            try await wait { isOn() && settled() }

            try await flip(name, in: settings)
            try await wait { !isOn() && settled() }
            XCTAssertTrue(window.sheets.isEmpty, "Turning \(name) off must not ask")
        }
    }

    func testUnsupportedHarnessHasNoAppsSwitch() async throws {
        let f = try fixture()
        _ = try f.repository.updateAgent(f.a, displayName: f.a.displayName,
            harnessIdentifier: HarnessProvider.apple.rawValue, modelIdentifier: nil, reasoningEffort: nil)
        f.store.reload()
        let settings = host(BotsSettingsView(store: f.store).environment(f.store))
        _ = try await control("Ada, account apps unavailable", in: settings)
        XCTAssertFalse(hasControl("Ada, account apps", in: settings))
        XCTAssertTrue(hasControl("Grace, account apps", in: settings))
    }

    private func snapshot(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["NOODLE_APPS_SCREENSHOT_DIRECTORY"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func confirm(_ title: String, with button: String, in window: NSWindow) async throws {
        try await wait { !window.sheets.isEmpty }
        let content = try XCTUnwrap(window.sheets.first?.contentView)
        _ = try await control(title, in: content)
        press(try await control(button, in: content))
        try await wait { window.sheets.isEmpty }
    }

    private func flip(_ name: String, in view: NSView) async throws {
        // Labels-hidden SwiftUI switches expose virtual checkboxes whose press
        // action does not forward to NSSwitch in this in-process test host.
        let label = try await control(name, in: view)
        let frame = try XCTUnwrap((label.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
        let toggle = try XCTUnwrap(elements(view).compactMap { $0 as? NSSwitch }.first {
            frame.contains(.init(x: $0.accessibilityFrame().midX, y: $0.accessibilityFrame().midY))
        })
        toggle.state = toggle.state == .on ? .off : .on
        XCTAssertTrue(toggle.sendAction(toggle.action, to: toggle.target))
    }
}
