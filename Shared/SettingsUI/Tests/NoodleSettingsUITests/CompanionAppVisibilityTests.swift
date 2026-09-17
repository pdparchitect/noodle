import AppKit
import Combine
import XCTest
@testable import NoodleSettingsUI

@MainActor final class CompanionAppVisibilityTests: XCTestCase {
    func testIndependentChoicesSurviveRelaunchWithoutChangingAnotherApp() throws {
        let defaults = try isolatedDefaults()
        let other = CompanionAppVisibility(defaults: try isolatedDefaults(), setPolicy: { _ in })
        var policies: [NSApplication.ActivationPolicy] = []
        let settings = CompanionAppVisibility(defaults: defaults, setPolicy: { policies.append($0) })
        XCTAssertTrue(settings.showInDock)
        XCTAssertFalse(settings.showMenuBar)
        XCTAssertTrue(policies.isEmpty, "Constructing settings must not activate the app before launch")
        settings.start()
        XCTAssertEqual(policies, [.regular])

        for dock in [false, true] {
            for menu in [false, true] {
                settings.showInDock = dock
                let policyCount = policies.count
                settings.showMenuBar = menu
                XCTAssertEqual(policies.count, policyCount, "Menu visibility must not change Dock visibility")
                let restored = CompanionAppVisibility(defaults: defaults, setPolicy: { policies.append($0) })
                XCTAssertEqual(restored.showInDock, dock)
                XCTAssertEqual(restored.showMenuBar, menu)
                restored.start()
                XCTAssertEqual(policies.last, dock ? .regular : .accessory)
            }
        }
        XCTAssertTrue(other.showInDock)
        XCTAssertFalse(other.showMenuBar)
    }

    func testExistingAppletMenuPreferenceIsPreserved() throws {
        let defaults = try isolatedDefaults()
        defaults.set(true, forKey: "showMenuBar")
        let settings = CompanionAppVisibility(defaults: defaults, setPolicy: { _ in })
        XCTAssertTrue(settings.showMenuBar)
        XCTAssertTrue(settings.showInDock)
        settings.showInDock = false
        XCTAssertTrue(defaults.bool(forKey: "showMenuBar"))
    }

    func testRepeatedMenuInsertionValuesDoNotInvalidateTheAppGraph() throws {
        let settings = CompanionAppVisibility(defaults: try isolatedDefaults(), setPolicy: { _ in })
        var changes = 0
        let observation = settings.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        settings.showMenuBar = false
        settings.showInDock = true
        XCTAssertEqual(changes, 0)
        settings.showMenuBar = true
        XCTAssertEqual(changes, 1)
        settings.showMenuBar = true
        XCTAssertEqual(changes, 1)
    }

    func testFixturesRemainAccessoryWhenDockPreferenceChanges() throws {
        var policies: [NSApplication.ActivationPolicy] = []
        let settings = CompanionAppVisibility(defaults: try isolatedDefaults(), setPolicy: { policies.append($0) })
        settings.start(permitsDock: false)
        settings.showInDock = false
        settings.showInDock = true
        XCTAssertEqual(policies, [.accessory, .accessory, .accessory])
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "NoodleVisibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
