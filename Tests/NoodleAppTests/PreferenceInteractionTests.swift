import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class PreferenceInteractionTests: HiddenViewTests {
    private func reopenedDefaults(_ f: StoreFixture) throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: f.runtime.suite))
    }
    private func checked(_ node: NSObject) -> Bool {
        if let toggle = node as? NSSwitch { return toggle.state == .on }
        return (attribute(node, .value) as? NSNumber)?.boolValue == true
    }
    private func toggle(_ name: String, in root: NSView) async throws -> NSSwitch {
        var result: NSSwitch?
        do {
            try await wait {
                for node in self.elements(root) {
                    let children = self.elements(node)
                    guard children.contains(where: { self.matches(name, node: $0) }) else { continue }
                    let switches = children.compactMap { $0 as? NSSwitch }
                    if switches.count == 1 { result = switches[0]; return true }
                }
                // Labels-hidden SwiftUI toggles expose a virtual checkbox. Match
                // that public accessibility frame to the native switch beneath it.
                if let label = self.elements(root).first(where: { self.matches(name, node: $0) }),
                   label.responds(to: NSSelectorFromString("accessibilityFrame")),
                   let frame = (label.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue {
                    let matches = self.elements(root).compactMap { $0 as? NSSwitch }.filter {
                        abs($0.accessibilityFrame().midY - frame.midY) < 2
                    }
                    if matches.count == 1 { result = matches[0]; return true }
                }
                return false
            }
        } catch { print("Missing switch: \(name). " + describe(root)); throw error }
        return try XCTUnwrap(result)
    }
    private func flip(_ toggle: NSSwitch) {
        toggle.state = toggle.state == .on ? .off : .on
        _ = toggle.sendAction(toggle.action, to: toggle.target)
    }

    func testBotNameStylePersistsAndReopensWithTheSelectedChoice() async throws {
        let f = try fixture()
        let settings = host(GeneralSettingsView().environment(f.store).defaultAppStorage(f.runtime.defaults))
        for style in [BotNameStyle.playful, .real] {
            press(try await control(style.displayName, in: settings))
            try await wait { f.runtime.defaults.string(forKey: BotNameStyle.defaultsKey) == style.rawValue }
            let reopened = host(GeneralSettingsView().environment(f.store).defaultAppStorage(try reopenedDefaults(f)))
            let selection = try await control(style.displayName, in: reopened)
            XCTAssertTrue(checked(selection))
        }
    }

    func testAwakePreferencePersistsIntoANewRuntimeAndSettingsView() async throws {
        let f = try fixture()
        let settings = host(GeneralSettingsView().environment(f.store).defaultAppStorage(f.runtime.defaults))
        let toggle = try await toggle("Keep Mac awake while agents work", in: settings)
        for expected in [true, false] {
            flip(toggle)
            try await wait { f.runtime.runtime.preventIdleSleepWhileWorking == expected }
            let defaults = try reopenedDefaults(f)
            let runtime = AgentRuntimeCoordinator(discovery: f.runtime.discovery, defaults: defaults,
                makeProcess: { launch in XCTFail("Settings must not launch agents"); return RuntimeProcessFixture(launch) })
            let store = NoodleStore(repository: f.repository, runtime: runtime, connectsServices: false)
            addTeardownBlock { @MainActor in store.stopMonitoring(); runtime.stopAll() }
            XCTAssertEqual(runtime.preventIdleSleepWhileWorking, expected)
            let reopened = host(GeneralSettingsView().environment(store).defaultAppStorage(defaults))
            let restored = try await self.toggle("Keep Mac awake while agents work", in: reopened)
            XCTAssertEqual(checked(restored), expected)
        }
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)
    }

    func testAttachmentLayoutsPersistAndRestoreTheSelectionAfterReopen() async throws {
        let f = try fixture()
        let settings = host(ChatSettingsView(microphoneDevices: { [] }, systemMicrophoneID: { 0 }).defaultAppStorage(f.runtime.defaults))
        for layout in [ChatAttachmentLayout.stack, .vertical, .wrap] {
            press(try await control(layout.displayName, in: settings))
            try await wait { f.runtime.defaults.string(forKey: ChatAttachmentLayout.defaultsKey) == layout.rawValue }
            let reopened = host(ChatSettingsView(microphoneDevices: { [] }, systemMicrophoneID: { 0 })
                .defaultAppStorage(try reopenedDefaults(f)))
            _ = try await control(layout.explanation, in: reopened)
            let selected = try await control(layout.displayName, in: reopened)
            XCTAssertTrue(checked(selected))
        }
    }

    func testNameMenuDescriptionsCanBeDisabledAndRestoredAcrossReopen() async throws {
        let f = try fixture()
        let settings = host(ChatSettingsView(microphoneDevices: { [] }, systemMicrophoneID: { 0 }).defaultAppStorage(f.runtime.defaults))
        let toggle = try await toggle("Show descriptions in the @ name menu", in: settings)
        XCTAssertTrue(checked(toggle))
        for expected in [false, true] {
            flip(toggle)
            try await wait { f.runtime.defaults.object(forKey: ComposerNameCompletion.descriptionsDefaultsKey) as? Bool == expected }
            let reopened = host(ChatSettingsView(microphoneDevices: { [] }, systemMicrophoneID: { 0 })
                .defaultAppStorage(try reopenedDefaults(f)))
            let restored = try await self.toggle("Show descriptions in the @ name menu", in: reopened)
            XCTAssertEqual(checked(restored), expected)
        }
    }

    func testSavedDeliveryModesRestoreTheVisibleSelectionUsedByMessageRouting() async throws {
        let f = try fixture()
        for mode in MessageDeliveryMode.allCases {
            f.runtime.defaults.set(mode.rawValue, forKey: MessageDeliveryMode.defaultsKey)
            XCTAssertEqual(MessageDeliveryMode.load(from: try reopenedDefaults(f)), mode)
            let reopened = host(ChatSettingsView(microphoneDevices: { [] }, systemMicrophoneID: { 0 })
                .defaultAppStorage(try reopenedDefaults(f)))
            _ = try await control(mode.displayName, in: reopened)
        }
    }

    func testSavedPreviewTimeoutsReopenWithTheTimeoutUsedByNewPreviews() async throws {
        let f = try fixture()
        for seconds in LinkPreviewSettings.timeoutOptions {
            f.runtime.defaults.set(seconds, forKey: LinkPreviewSettings.timeoutKey)
            let defaults = try reopenedDefaults(f)
            let reopened = host(ChatSettingsView(microphoneDevices: { [] }, systemMicrophoneID: { 0 }).defaultAppStorage(defaults))
            _ = try await control("\(seconds) seconds", in: reopened)
            XCTAssertEqual(LinkPreviewSettings.timeout(in: defaults), TimeInterval(seconds))
        }
    }

    func testMicrophoneUIDSurvivesReopenDisconnectionAndReconnection() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Microphone settings require macOS 26") }
        let f = try fixture()
        let microphones = [VoiceInputDevice(id: "fixture-built-in", name: "Built-in fixture", audioID: 11),
            VoiceInputDevice(id: "fixture-usb", name: "USB fixture", audioID: 22)]
        f.runtime.defaults.set("fixture-usb", forKey: VoiceInputDevice.defaultsKey)
        let settings = host(ChatSettingsView(microphoneDevices: { microphones }, systemMicrophoneID: { 11 })
            .defaultAppStorage(try reopenedDefaults(f)))
        _ = try await control("USB fixture", in: settings)
        let disconnected = host(ChatSettingsView(microphoneDevices: { [microphones[0]] }, systemMicrophoneID: { 11 })
            .defaultAppStorage(try reopenedDefaults(f)))
        _ = try await control("Selected microphone unavailable", in: disconnected)
        XCTAssertEqual(try reopenedDefaults(f).string(forKey: VoiceInputDevice.defaultsKey), "fixture-usb")
        let reconnected = host(ChatSettingsView(microphoneDevices: { microphones }, systemMicrophoneID: { 11 })
            .defaultAppStorage(try reopenedDefaults(f)))
        _ = try await control("USB fixture", in: reconnected)
        XCTAssertEqual(try reopenedDefaults(f).string(forKey: VoiceInputDevice.defaultsKey), "fixture-usb")
        f.runtime.defaults.set("", forKey: VoiceInputDevice.defaultsKey)
        let systemDefault = host(ChatSettingsView(microphoneDevices: { microphones }, systemMicrophoneID: { 11 })
            .defaultAppStorage(try reopenedDefaults(f)))
        _ = try await control("System Default — Built-in fixture", in: systemDefault)
    }

    func testHeartbeatControlsPersistGlobalAndPerBotSettingsAcrossRuntimeRecreation() async throws {
        let f = try fixture()
        f.runtime.runtime.configureHeartbeats(intervalMinutes: 7)
        let settings = host(HeartbeatsSettingsView().environment(f.store))
        _ = try await control("7 minutes", in: settings)
        flip(try await toggle("Heartbeat for Ada", in: settings))
        try await wait { f.runtime.runtime.heartbeatConfiguration.disabledAgentIDs == [f.a.id] }
        let global = try await toggle("Wake idle agents", in: settings)
        flip(global)
        try await wait { !f.runtime.runtime.heartbeatConfiguration.isEnabled }
        let member = try await toggle("Heartbeat for Grace", in: settings)
        try await wait { !self.enabled(member) }
        let runtime = AgentRuntimeCoordinator(discovery: f.runtime.discovery, defaults: try reopenedDefaults(f))
        XCTAssertEqual(runtime.heartbeatConfiguration, f.runtime.runtime.heartbeatConfiguration)
        XCTAssertEqual(runtime.heartbeatConfiguration.disabledAgentIDs, [f.a.id])
        XCTAssertEqual(runtime.heartbeatConfiguration.intervalMinutes, 7)
        flip(global)
        try await wait { f.runtime.runtime.heartbeatConfiguration.isEnabled }
        let ada = try await toggle("Heartbeat for Ada", in: settings)
        let grace = try await toggle("Heartbeat for Grace", in: settings)
        XCTAssertFalse(checked(ada)); XCTAssertTrue(checked(grace))
        XCTAssertEqual(AgentHeartbeatConfiguration.load(from: try reopenedDefaults(f)), f.runtime.runtime.heartbeatConfiguration)
    }
}
