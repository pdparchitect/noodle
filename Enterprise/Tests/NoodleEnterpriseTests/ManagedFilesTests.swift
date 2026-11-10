// Noodle Enterprise. Source-available under Enterprise/LICENSE, not Apache-2.0.
import Foundation
import NoodleCore
import XCTest
@testable import NoodleEnterprise

/// The Jamf schema, sample profile and guide are a public contract with administrators: they must
/// say exactly what the app does.
final class ManagedFilesTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func committed(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testCommittedFilesAreWhatTheRegistryGenerates() throws {
        for (path, contents) in try ManagedFiles.expected(root: root) {
            XCTAssertEqual(try committed(path), contents, "\(path) differs from the key registry. Run: swift run NoodleEnterpriseFiles")
        }
    }

    func testNoPublishedKeyEverLeavesTheRegistry() throws {
        let published = try committed(ManagedFiles.ledgerPath).split(whereSeparator: \.isNewline).map(String.init)
        let schema = try JSONSerialization.jsonObject(with: Data(committed(ManagedFiles.schemaPath).utf8)) as? [String: Any]
        let inSchema = (schema?["properties"] as? [String: Any])?.keys.map { $0 } ?? []
        let names = Set(ManagedKeys.all.map(\.name))
        for key in published + inSchema {
            XCTAssertTrue(names.contains(key), "\(key) was published; keep it in the registry as deprecated instead of removing it.")
        }
        XCTAssertEqual(names.count, ManagedKeys.all.count, "Key names are unique")
    }

    func testSchemaDefaultsAreTheAppsOwn() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(committed(ManagedFiles.schemaPath).utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        func defaultValue(_ key: String) -> Any? { properties[key]?["default"] }
        let unmanaged = UnmanagedPolicy()
        let actions: [String: OrganisationAction] = [
            ManagedKeys.allowUnrestrictedAccess: .unrestrictedAccess,
            ManagedKeys.allowMCP: .toolConnections,
            ManagedKeys.allowCustomMCP: .toolConnection(catalogueID: nil, endpoint: URL(string: "https://mcp.example.com")!),
            ManagedKeys.allowBrowser: .browsers, ManagedKeys.allowComputers: .computers, ManagedKeys.allowHubHosting: .hubHosting,
            ManagedKeys.allowHubConnections: .hubConnections, ManagedKeys.allowUpdates: .updates,
        ]
        for (key, action) in actions {
            XCTAssertEqual(defaultValue(key) as? Bool, unmanaged.allows(action), key)
        }
        XCTAssertEqual(defaultValue(ManagedKeys.allowedHarnesses) as? [String], HarnessProvider.allCases.map(\.rawValue))
        // A template, with build settings still to fill in, so not a property list yet.
        let info = try committed("Support/Info.plist")
        func sparkle(_ key: String) throws -> Bool? {
            let match = try XCTUnwrap(info.firstMatch(of: try Regex("<key>\(key)</key>\\s*<(true|false)/>")))
            return (match.output[1].substring).map { $0 == "true" }
        }
        XCTAssertEqual(defaultValue(ManagedKeys.automaticUpdateChecks) as? Bool, try sparkle("SUEnableAutomaticChecks"))
        XCTAssertEqual(defaultValue(ManagedKeys.automaticUpdateInstalls) as? Bool, try sparkle("SUAutomaticallyUpdate"))
        XCTAssertEqual(ManagedKeys.automaticUpdateChecksDefault, try sparkle("SUEnableAutomaticChecks"))
        for key in ManagedKeys.all where key.type == .boolean {
            XCTAssertNotNil(defaultValue(key.name) as? Bool, "\(key.name) has a default")
        }
    }

    func testTheSampleProfileForcesEveryKeyWithoutChangingWhatNoodleDoes() throws {
        let data = try Data(committed(ManagedFiles.profilePath).utf8)
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        let payload = try XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
        let domain = try XCTUnwrap((payload["PayloadContent"] as? [String: Any])?[ManagedKeys.domain] as? [String: Any])
        let settings = try XCTUnwrap((domain["Forced"] as? [[String: Any]])?.first?["mcx_preference_settings"] as? [String: Any])
        let policy = ManagedPolicy(reading: ForcedValues(values: settings))
        XCTAssertTrue(policy.problems.isEmpty)
        XCTAssertTrue(HarnessProvider.allCases.allSatisfy { policy.allows(.harness($0)) })
        for action: OrganisationAction in [.unrestrictedAccess, .browsers, .computers, .hubHosting, .hubConnections, .updates,
                                           .hubAddress("hub.example.com"),
                                           .toolConnection(catalogueID: nil, endpoint: URL(string: "https://mcp.example.com")!)] {
            XCTAssertTrue(policy.allows(action), "\(action)")
        }
        XCTAssertEqual(Set(settings.keys), Set(ManagedKeys.all.filter { $0.defaultValue != nil || $0.name.hasSuffix("DenyList") }.map(\.name)))
    }

    func testTheGuideTableListsEveryKey() throws {
        let guide = try committed(ManagedFiles.guidePath)
        for key in ManagedKeys.all { XCTAssertTrue(guide.contains("| `\(key.name)` |"), key.name) }
        XCTAssertTrue(guide.contains(ManagedKeys.domain))
    }
}
