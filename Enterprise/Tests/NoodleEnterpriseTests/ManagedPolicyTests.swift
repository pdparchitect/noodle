// Noodle Enterprise. Source-available under Enterprise/LICENSE, not Apache-2.0.
import Foundation
import NoodleCore
import XCTest
@testable import NoodleEnterprise

/// What a profile forced, as macOS reports it.
struct ForcedValues: ManagedPreferenceSource, @unchecked Sendable {
    var values: [String: Any]
    func forcedValue(forKey key: String) -> Any? { values[key] }
}

final class ManagedPolicyTests: XCTestCase {
    private func policy(_ values: [String: Any]) -> ManagedPolicy { ManagedPolicy(reading: ForcedValues(values: values)) }
    private let custom = URL(string: "https://mcp.example.com/mcp")!
    private func catalogue(_ id: String) -> OrganisationAction {
        let tool = ToolCatalog.entries.first { $0.id == id }!
        guard case .mcp(let configuration) = tool.configuration else { fatalError() }
        return .toolConnection(catalogueID: id, endpoint: configuration.endpoint)
    }

    /// A valid value for each key that differs from what Noodle does without it.
    private func restrictive(_ key: ManagedKey) -> Any {
        switch key.type {
        case .boolean:
            if case .boolean(let flag)? = key.defaultValue { return !flag }
            return false
        case .strings:
            return [key.choices?.first?.value ?? "blocked.example.com"]
        }
    }

    func testNoProfileAllowsEverythingAndListsNothing() {
        let empty = policy([:])
        XCTAssertTrue(HarnessProvider.allCases.allSatisfy { empty.allows(.harness($0)) })
        for action: OrganisationAction in [.unrestrictedAccess, .toolConnections, .browsers, .computers, .hubHosting, .hubConnections,
                                           .hubAddress("hub.example.com"), .updates, catalogue("linear"),
                                           .toolConnection(catalogueID: nil, endpoint: custom)] {
            XCTAssertTrue(empty.allows(action), "\(action)")
        }
        XCTAssertNil(empty.value(of: .automaticUpdateChecks))
        XCTAssertNil(empty.value(of: .automaticUpdateInstalls))
        XCTAssertTrue(empty.rules.isEmpty)
        XCTAssertEqual(empty, ManagedPolicy())
    }

    func testEveryKeyIsReadWhenForcedAndIgnoredWhenAbsentOrOnlyThePersonsOwn() {
        let suite = "Noodle.ManagedPolicyTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ManagedKeys.all {
            let value = restrictive(key)
            XCTAssertNil(policy([:]).values[key.name], key.name)
            defaults.set(value, forKey: key.name)
            // Written by the person, not forced by a profile: theirs, not their organisation's.
            XCTAssertNil(ManagedPolicy(reading: DefaultsPreferenceSource(defaults)).values[key.name], key.name)
            let forced = policy([key.name: value])
            XCTAssertNotNil(forced.values[key.name], key.name)
            XCTAssertEqual(forced.rules.map(\.title), [key.title])
        }
    }

    func testWrongTypesAreIgnoredAndLoggedWithoutWideningAnything() {
        let wrong = policy([ManagedKeys.allowBrowser: "false", ManagedKeys.allowComputers: 0,
                            ManagedKeys.allowedHarnesses: "codex", ManagedKeys.hubDenyList: ["hub.example.com", 7, ""]])
        XCTAssertTrue(wrong.allows(.browsers))
        XCTAssertTrue(wrong.allows(.computers))
        XCTAssertTrue(wrong.allows(.harness(.claudeCode)))
        XCTAssertFalse(wrong.allows(.hubAddress("hub.example.com")), "Valid entries of a list stay")
        XCTAssertEqual(wrong.problems.count, 5)
        XCTAssertEqual(wrong.values.keys.sorted(), [ManagedKeys.hubDenyList])
    }

    func testHarnessesOutsideTheAllowListAreBlockedAndUnknownOnesAreLeftOut() {
        let some = policy([ManagedKeys.allowedHarnesses: ["codex", "not-a-harness"]])
        XCTAssertTrue(some.allows(.harness(.codex)))
        XCTAssertFalse(some.allows(.harness(.claudeCode)))
        XCTAssertEqual(some.problems.count, 1)
        let none = policy([ManagedKeys.allowedHarnesses: [String]()])
        XCTAssertFalse(HarnessProvider.allCases.contains { none.allows(.harness($0)) }, "An empty allow list allows nothing")
        XCTAssertEqual(none.rules, [OrganisationRule(title: "Allowed harnesses", value: "None")])
        XCTAssertEqual(some.rules, [OrganisationRule(title: "Allowed harnesses", value: "Codex")])
    }

    func testBooleanPolicies() {
        let off = policy([ManagedKeys.allowUnrestrictedAccess: false, ManagedKeys.allowBrowser: false, ManagedKeys.allowComputers: false,
                          ManagedKeys.allowHubHosting: false, ManagedKeys.allowUpdates: false,
                          ManagedKeys.automaticUpdateChecks: false, ManagedKeys.automaticUpdateInstalls: true])
        for action: OrganisationAction in [.unrestrictedAccess, .browsers, .computers, .hubHosting, .updates] {
            XCTAssertFalse(off.allows(action), "\(action)")
        }
        XCTAssertTrue(off.allows(.hubConnections))
        XCTAssertEqual(off.value(of: .automaticUpdateChecks), false)
        XCTAssertEqual(off.value(of: .automaticUpdateInstalls), true)
        XCTAssertTrue(off.rules.contains(OrganisationRule(title: "Check for updates automatically", value: "Off")))
        XCTAssertTrue(off.rules.contains(OrganisationRule(title: "Allow Noodle Browser", value: "Not allowed")))
        let on = policy([ManagedKeys.allowBrowser: true])
        XCTAssertTrue(on.allows(.browsers))
        XCTAssertEqual(on.rules, [OrganisationRule(title: "Allow Noodle Browser", value: "Allowed")])
    }

    func testToolConnectionsOffBlocksCatalogueAndCustomOnes() {
        let off = policy([ManagedKeys.allowMCP: false, ManagedKeys.mcpAllowList: ["linear"]])
        XCTAssertFalse(off.allows(.toolConnections))
        XCTAssertFalse(off.allows(catalogue("linear")))
        XCTAssertFalse(off.allows(.toolConnection(catalogueID: nil, endpoint: custom)))
    }

    func testCatalogueListsMatchByIDAndDenyWins() {
        let lists = policy([ManagedKeys.mcpAllowList: ["linear", "asana"], ManagedKeys.mcpDenyList: ["asana"]])
        XCTAssertTrue(lists.allows(catalogue("linear")))
        XCTAssertFalse(lists.allows(catalogue("asana")), "Deny wins over allow")
        XCTAssertFalse(lists.allows(catalogue("airtable")), "An allow list means only these")
        XCTAssertTrue(lists.allows(.toolConnection(catalogueID: nil, endpoint: custom)), "Catalogue lists leave custom servers alone")
        let denied = policy([ManagedKeys.mcpDenyList: ["airtable"]])
        XCTAssertTrue(denied.allows(catalogue("linear")))
        XCTAssertFalse(denied.allows(catalogue("airtable")))
    }

    func testCustomServersMatchByHostDomainOrURLPrefix() {
        let off = policy([ManagedKeys.allowCustomMCP: false])
        XCTAssertFalse(off.allows(.toolConnection(catalogueID: nil, endpoint: custom)))
        XCTAssertTrue(off.allows(catalogue("linear")))
        let lists = policy([ManagedKeys.customMCPAllowList: ["*.Example.com", "https://tools.corp.test/mcp"],
                            ManagedKeys.customMCPDenyList: ["bad.example.com"]])
        func allows(_ url: String) -> Bool { lists.allows(.toolConnection(catalogueID: nil, endpoint: URL(string: url)!)) }
        XCTAssertTrue(allows("https://mcp.example.com/mcp"))
        XCTAssertTrue(allows("https://example.com/mcp"))
        XCTAssertFalse(allows("https://bad.example.com/mcp"), "Deny wins over allow")
        XCTAssertFalse(allows("https://example.com.evil.test/mcp"))
        XCTAssertTrue(allows("https://tools.corp.test/mcp"))
        XCTAssertTrue(allows("https://tools.corp.test/mcp/sse"))
        XCTAssertFalse(allows("https://tools.corp.test/mcp-other"), "A URL prefix matches whole path segments")
        XCTAssertFalse(allows("https://tools.corp.test/"))
        XCTAssertFalse(allows("https://other.test/mcp"), "An allow list means only these")
    }

    func testHubConnectionsAndAddresses() {
        let off = policy([ManagedKeys.allowHubConnections: false])
        XCTAssertFalse(off.allows(.hubConnections))
        XCTAssertFalse(off.allows(.hubAddress("hub.example.com")))
        let lists = policy([ManagedKeys.hubAllowList: ["*.corp.test", "10.0.0.5"], ManagedKeys.hubDenyList: ["old.corp.test"]])
        XCTAssertTrue(lists.allows(.hubConnections))
        XCTAssertTrue(lists.allows(.hubAddress("hub.corp.test")))
        XCTAssertTrue(lists.allows(.hubAddress("10.0.0.5")))
        XCTAssertFalse(lists.allows(.hubAddress("old.corp.test")))
        XCTAssertFalse(lists.allows(.hubAddress("192.168.1.4")))
        XCTAssertFalse(lists.allows(.hubAddress("corp.test.evil.example")))
    }
}

@MainActor final class ManagedPreferencesTests: XCTestCase {
    /// Everything in the suite counts as forced, as a profile's values would.
    private struct Suite: ManagedPreferenceSource, @unchecked Sendable {
        let defaults: UserDefaults
        func forcedValue(forKey key: String) -> Any? { defaults.object(forKey: key) }
    }

    override func tearDown() async throws {
        await MainActor.run { Organisation.enforce(UnmanagedPolicy()) }
    }

    func testAProfileInstalledOrRemovedWhileTheAppRunsTakesEffectAtOnce() async throws {
        let name = "Noodle.ManagedPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ManagedPreferences(defaults: defaults, source: Suite(defaults: defaults))
        preferences.start(rereadingEvery: nil)
        defer { preferences.stop() }
        XCTAssertTrue(Organisation.allows(.browsers))

        var installed = expectation(forNotification: Organisation.didChangeNotification, object: nil)
        defaults.set(false, forKey: ManagedKeys.allowBrowser)
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertFalse(Organisation.allows(.browsers))
        XCTAssertFalse(OrganisationStatus.shared.allows(.browsers))
        XCTAssertTrue(OrganisationStatus.shared.isManaged)

        installed = expectation(forNotification: Organisation.didChangeNotification, object: nil)
        defaults.removeObject(forKey: ManagedKeys.allowBrowser)
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertTrue(Organisation.allows(.browsers))
        XCTAssertFalse(OrganisationStatus.shared.isManaged)
    }

    func testRereadingAnUnchangedProfileTellsNobody() {
        let preferences = ManagedPreferences(defaults: UserDefaults(suiteName: "Noodle.ManagedPreferencesTests.\(UUID())")!,
                                             source: ForcedValues(values: [ManagedKeys.allowComputers: false]))
        var notices = 0
        let observer = NotificationCenter.default.addObserver(forName: Organisation.didChangeNotification, object: nil, queue: nil) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        preferences.refresh()
        preferences.refresh()
        XCTAssertEqual(notices, 1)
        XCTAssertFalse(Organisation.allows(.computers))
    }
}
