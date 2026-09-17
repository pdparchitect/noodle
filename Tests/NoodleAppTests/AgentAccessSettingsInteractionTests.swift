import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class AgentAccessSettingsInteractionTests: HiddenViewTests {
    func testAppsDefaultsOffAndTogglesIndependentlyWithClickableExplanation() async throws {
        let f = try fixture()
        let settings = host(AgentAccessSettingsView().environment(f.store).preferredColorScheme(.dark))
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
        try await wait { f.runtime.runtime.accessConfiguration.appsEnabled(for: f.a) && !f.runtime.runtime.changingAccess.contains(f.a.id) }
        XCTAssertFalse(f.runtime.runtime.accessConfiguration.isExtended(for: f.a))
        XCTAssertTrue(try XCTUnwrap(f.runtime.factory.processes.last).launch.appsEnabled)
        _ = try await control("apps", in: settings)
        _ = try await control("·", in: settings)
        try snapshot(settings, name: "sandbox-restricted-apps")

        try await flip("Ada, unrestricted access", in: settings)
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

    func testUnsupportedHarnessHasNoAppsSwitch() async throws {
        let f = try fixture()
        _ = try f.repository.updateAgent(f.a, displayName: f.a.displayName,
            harnessIdentifier: HarnessProvider.apple.rawValue, modelIdentifier: nil, reasoningEffort: nil)
        f.store.reload()
        let settings = host(AgentAccessSettingsView().environment(f.store))
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
