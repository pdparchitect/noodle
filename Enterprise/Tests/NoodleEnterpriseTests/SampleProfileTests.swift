// Noodle Enterprise. Source-available under Enterprise/LICENSE, not Apache-2.0.
import Foundation
import NoodleCore
import XCTest
@testable import NoodleEnterprise

/// The committed sample profile's settings, made restrictive wherever the sample allows, with a few
/// entries an administrator could get wrong.
enum RestrictiveProfile {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Entries no valid profile has: the policy leaves them out and logs them, and the Jamf form
    /// would not accept them.
    static let unknownHarness = "not-a-harness"
    static let unknownKey = "NotANoodleKey"
    static let notAString = 7

    static func sampleProfile() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(ManagedFiles.profilePath))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// What the sample profile forces in Noodle's domain, without its Payload keys.
    static func sampleSettings() throws -> [String: Any] {
        let payloads = try XCTUnwrap(sampleProfile()["PayloadContent"] as? [[String: Any]])
        let domain = try XCTUnwrap(payloads.lazy.compactMap { ($0["PayloadContent"] as? [String: Any])?[ManagedKeys.domain] as? [String: Any] }.first)
        let settings = try XCTUnwrap((domain["Forced"] as? [[String: Any]])?.first?["mcx_preference_settings"] as? [String: Any])
        return settings.filter { !$0.key.hasPrefix("Payload") }
    }

    static func settings() throws -> [String: Any] {
        try sampleSettings().merging([
            ManagedKeys.allowedHarnesses: [HarnessProvider.codex.rawValue, unknownHarness],
            ManagedKeys.allowUnrestrictedAccess: false,
            ManagedKeys.mcpAllowList: ["linear", "asana"],
            ManagedKeys.mcpDenyList: ["asana"],
            ManagedKeys.customMCPAllowList: ["*.corp.test", notAString],
            ManagedKeys.customMCPDenyList: ["bad.corp.test"],
            ManagedKeys.allowBrowser: false,
            ManagedKeys.allowComputers: false,
            ManagedKeys.allowHubHosting: false,
            ManagedKeys.hubAllowList: ["*.corp.test"],
            ManagedKeys.hubDenyList: ["old.corp.test", ""],
            ManagedKeys.allowUpdates: false,
            ManagedKeys.automaticUpdateChecks: false,
            ManagedKeys.automaticUpdateInstalls: true,
            unknownKey: true,
        ]) { $1 }
    }
}

/// The committed sample profile, checked as a configuration profile, then its settings, made
/// restrictive, fed as forced values through the reader, policy and live observer the app uses.
/// This does not go through macOS's managed-preferences layer: GitHub's macOS runners ignore
/// managed preferences files written without an MDM, so installing a real profile is checked by hand.
@MainActor final class SampleProfileTests: XCTestCase {
    /// Everything in the suite counts as forced, as a profile's values would.
    private struct ForcedSuite: ManagedPreferenceSource, @unchecked Sendable {
        let defaults: UserDefaults
        func forcedValue(forKey key: String) -> Any? { defaults.object(forKey: key) }
    }

    override func tearDown() async throws {
        await MainActor.run { Organisation.enforce(UnmanagedPolicy()) }
    }

    func testTheSampleProfileIsAValidConfigurationProfileForNoodlesDomain() throws {
        let path = RestrictiveProfile.root.appendingPathComponent(ManagedFiles.profilePath).path
        let lint = Process()
        lint.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        lint.arguments = ["-lint", path]
        lint.standardOutput = FileHandle.nullDevice
        try lint.run()
        lint.waitUntilExit()
        XCTAssertEqual(lint.terminationStatus, 0, "plutil -lint \(ManagedFiles.profilePath)")

        let profile = try RestrictiveProfile.sampleProfile()
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(profile["PayloadVersion"] as? Int, 1)
        let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(payloads.count, 1)
        let payload = try XCTUnwrap(payloads.first)
        // The custom settings payload: macOS writes its Forced settings into the domain it names.
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.ManagedClient.preferences")
        XCTAssertEqual(payload["PayloadVersion"] as? Int, 1)
        XCTAssertEqual((payload["PayloadContent"] as? [String: Any]).map { Array($0.keys) }, [ManagedKeys.domain])
        for item in [profile, payload] {
            XCTAssertNotNil((item["PayloadUUID"] as? String).flatMap(UUID.init(uuidString:)), "PayloadUUID")
            XCTAssertTrue((item["PayloadIdentifier"] as? String)?.hasPrefix(ManagedKeys.domain) == true, "PayloadIdentifier")
        }
        XCTAssertNotEqual(profile["PayloadUUID"] as? String, payload["PayloadUUID"] as? String)

        let settings = try RestrictiveProfile.sampleSettings()
        let known = Set(ManagedKeys.all.map(\.name))
        XCTAssertEqual(Set(settings.keys).subtracting(known), [], "Every key is in the registry")
        XCTAssertEqual(try ManagedFilesTests.schemaViolations(settings), [])
        XCTAssertTrue(ManagedPolicy(reading: ForcedValues(values: settings)).problems.isEmpty)
    }

    func testTheSampleProfileInstalledChangedAndRemovedWhileTheAppRuns() async throws {
        let name = "Noodle.SampleProfileTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ManagedPreferences(defaults: defaults, source: ForcedSuite(defaults: defaults))
        var notices = 0
        let observer = NotificationCenter.default.addObserver(forName: Organisation.didChangeNotification, object: nil, queue: nil) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        preferences.start(rereadingEvery: nil)
        defer { preferences.stop() }
        XCTAssertTrue(preferences.policy.values.isEmpty)

        // Installed: every policy decides as the profile says, and invalid entries are left out.
        let profile = try RestrictiveProfile.settings()
        for (key, value) in profile { defaults.set(value, forKey: key) }
        try await waitUntil("the running observer puts the profile in force") {
            preferences.policy.values.count == ManagedKeys.all.count && !Organisation.allows(.updates)
        }
        XCTAssertGreaterThan(notices, 0)
        var policy = preferences.policy
        XCTAssertEqual(policy.problems.count, 3, "\(policy.problems)")
        for key in [ManagedKeys.allowedHarnesses, ManagedKeys.customMCPAllowList, ManagedKeys.hubDenyList] {
            XCTAssertTrue(policy.problems.contains { $0.hasPrefix(key) }, "\(key): \(policy.problems)")
        }

        XCTAssertTrue(policy.allows(.harness(.codex)))
        XCTAssertFalse(HarnessProvider.allCases.contains { $0 != .codex && policy.allows(.harness($0)) })
        XCTAssertFalse(policy.allows(.unrestrictedAccess))
        XCTAssertTrue(policy.allows(.toolConnections))
        XCTAssertTrue(policy.allows(catalogueConnection("linear")))
        XCTAssertFalse(policy.allows(catalogueConnection("asana")), "Deny wins over allow")
        XCTAssertFalse(policy.allows(catalogueConnection("airtable")), "An allow list means only these")
        XCTAssertTrue(policy.allows(customConnection("https://mcp.corp.test/mcp")))
        XCTAssertFalse(policy.allows(customConnection("https://bad.corp.test/mcp")))
        XCTAssertFalse(policy.allows(customConnection("https://mcp.example.com/mcp")))
        XCTAssertFalse(policy.allows(.browsers))
        XCTAssertFalse(policy.allows(.computers))
        XCTAssertFalse(policy.allows(.hubHosting))
        XCTAssertTrue(policy.allows(.hubConnections))
        XCTAssertTrue(policy.allows(.hubAddress("hub.corp.test")))
        XCTAssertFalse(policy.allows(.hubAddress("old.corp.test")))
        XCTAssertFalse(policy.allows(.hubAddress("hub.example.com")))
        XCTAssertFalse(policy.allows(.updates))
        XCTAssertEqual(policy.value(of: .automaticUpdateChecks), false)
        XCTAssertEqual(policy.value(of: .automaticUpdateInstalls), true)
        XCTAssertFalse(Organisation.allows(.unrestrictedAccess))
        XCTAssertTrue(OrganisationStatus.shared.isManaged)

        // Changed while running: the new values apply, and a value of the wrong type is ignored.
        let installed = notices
        defaults.set(false, forKey: ManagedKeys.allowMCP)
        defaults.set(false, forKey: ManagedKeys.allowHubConnections)
        defaults.set("false", forKey: ManagedKeys.allowComputers)
        try await waitUntil("the running observer puts the changed profile in force") {
            notices > installed && !Organisation.allows(.toolConnections) && !Organisation.allows(.hubConnections)
                && Organisation.allows(.computers)
        }
        policy = preferences.policy
        XCTAssertTrue(policy.problems.contains { $0.hasPrefix(ManagedKeys.allowComputers) }, "\(policy.problems)")
        XCTAssertFalse(policy.allows(catalogueConnection("linear")))
        XCTAssertFalse(policy.allows(customConnection("https://mcp.corp.test/mcp")))
        XCTAssertFalse(policy.allows(.hubAddress("hub.corp.test")))
        XCTAssertTrue(policy.allows(.computers))
        XCTAssertFalse(policy.allows(.browsers))

        // Removed: everything is allowed again.
        let beforeRemoval = notices
        for key in profile.keys { defaults.removeObject(forKey: key) }
        try await waitUntil("the running observer lifts the policy") { notices > beforeRemoval && preferences.policy.values.isEmpty }
        XCTAssertTrue(HarnessProvider.allCases.allSatisfy { Organisation.allows(.harness($0)) })
        for action: OrganisationAction in [.unrestrictedAccess, .toolConnections, catalogueConnection("asana"),
                                           customConnection("https://bad.corp.test/mcp"), .browsers, .computers, .hubHosting,
                                           .hubConnections, .hubAddress("old.corp.test"), .updates] {
            XCTAssertTrue(Organisation.allows(action), "\(action)")
        }
        XCTAssertNil(Organisation.policy.value(of: .automaticUpdateChecks))
        XCTAssertFalse(OrganisationStatus.shared.isManaged)
    }

    private func catalogueConnection(_ id: String) -> OrganisationAction {
        let tool = ToolCatalog.entries.first { $0.id == id }!
        guard case .mcp(let configuration) = tool.configuration else { fatalError("\(id) is not an MCP connection") }
        return .toolConnection(catalogueID: id, endpoint: configuration.endpoint)
    }

    private func customConnection(_ url: String) -> OrganisationAction {
        .toolConnection(catalogueID: nil, endpoint: URL(string: url)!)
    }

    /// Polls until `condition` holds; the observer applies each change on the main queue.
    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out after \(Int(timeout)) s waiting until \(what).") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
