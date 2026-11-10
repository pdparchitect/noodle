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

    /// What the sample profile forces in Noodle's domain, without its Payload keys.
    static func sampleSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(ManagedFiles.profilePath))
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
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

/// Installs a profile's settings where macOS keeps the managed preferences a System-scope profile
/// delivers, for a test-only domain, and reads them back through the reader and policy the app uses.
/// Writing there needs passwordless sudo, as GitHub's macOS runners have; elsewhere the test is skipped.
@MainActor final class ManagedProfileTests: XCTestCase {
    nonisolated static let domain = "com.pdparchitect.noodle.managed-test"
    nonisolated static let folder = URL(fileURLWithPath: "/Library/Managed Preferences")
    nonisolated static var file: URL { folder.appendingPathComponent("\(domain).plist") }
    /// Folders the test made, removed again when empty.
    nonisolated(unsafe) static var createdFolders: [URL] = []

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    override func setUp() async throws {
        let check = Self.run("/usr/bin/sudo", ["-n", "true"])
        guard check.status == 0 else {
            throw XCTSkip("Installing a managed preferences file needs passwordless sudo, as GitHub's macOS runners have: \(check.output)")
        }
        try Self.removeProfile()
    }

    /// Runs after a failure too, so no run leaves a managed file behind.
    override func tearDown() async throws {
        try Self.removeProfile()
        await MainActor.run { Organisation.enforce(UnmanagedPolicy()) }
    }

    func testAProfileInstalledChangedAndRemovedGoesThroughMacOSManagedPreferences() async throws {
        let domain = Self.domain as CFString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.domain))
        func forced(_ key: String) -> Bool { CFPreferencesAppValueIsForced(key as CFString, domain) }
        XCTAssertFalse(ManagedKeys.all.contains { forced($0.name) }, "Nothing is managed before the profile")

        let preferences = ManagedPreferences(defaults: defaults)
        var notices = 0
        let observer = NotificationCenter.default.addObserver(forName: Organisation.didChangeNotification, object: nil, queue: nil) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        preferences.start(rereadingEvery: 0.5)
        defer { preferences.stop() }
        XCTAssertTrue(preferences.policy.values.isEmpty)

        // Installed: every key is forced, and every policy decides as the profile says.
        let profile = try RestrictiveProfile.settings()
        try Self.install(profile)
        try await waitUntil("the profile's values are forced") { profile.keys.allSatisfy(forced) }
        for key in profile.keys {
            XCTAssertTrue(defaults.objectIsForced(forKey: key), key)
        }
        try await waitUntil("the running observer puts the profile in force") { notices > 0 && !Organisation.allows(.browsers) }
        var policy = preferences.policy
        XCTAssertEqual(Set(policy.values.keys), Set(ManagedKeys.all.map(\.name)))
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
        var changed = profile
        changed[ManagedKeys.allowMCP] = false
        changed[ManagedKeys.allowHubConnections] = false
        changed[ManagedKeys.allowComputers] = "false"
        let installed = notices
        try Self.install(changed)
        try await waitUntil("the running observer puts the changed profile in force") {
            notices > installed && !Organisation.allows(.toolConnections) && !Organisation.allows(.hubConnections)
                && Organisation.allows(.computers)
        }
        policy = preferences.policy
        XCTAssertTrue(forced(ManagedKeys.allowComputers))
        XCTAssertTrue(policy.problems.contains { $0.hasPrefix(ManagedKeys.allowComputers) }, "\(policy.problems)")
        XCTAssertFalse(policy.allows(catalogueConnection("linear")))
        XCTAssertFalse(policy.allows(customConnection("https://mcp.corp.test/mcp")))
        XCTAssertFalse(policy.allows(.hubAddress("hub.corp.test")))
        XCTAssertTrue(policy.allows(.computers))
        XCTAssertFalse(policy.allows(.browsers))

        // Removed: nothing is forced and everything is allowed again.
        let beforeRemoval = notices
        try Self.removeProfile()
        try await waitUntil("the removed profile's values are no longer forced") { !profile.keys.contains(where: forced) }
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

    /// Polls until `condition` holds; macOS takes a moment to read managed preferences again.
    private func waitUntil(_ what: String, timeout: TimeInterval = 60, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                let listing = Self.run("/bin/ls", ["-l", Self.folder.path]).output
                let seen = Self.run("/usr/bin/defaults", ["read", Self.domain]).output
                let enrollment = Self.run("/usr/bin/sudo", ["-n", "/usr/bin/profiles", "status", "-type", "enrollment"]).output
                let system = Self.run("/usr/bin/sw_vers", []).output
                throw Failure("Timed out after \(Int(timeout)) s waiting until \(what). \(Self.folder.path): \(listing)\ndefaults read \(Self.domain): \(seen)\nprofiles status -type enrollment: \(enrollment)\nsw_vers: \(system)")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Writes `settings` as the managed preferences file for the test domain, as an MDM profile
    /// would leave it: owned by root, readable by all.
    nonisolated static func install(_ settings: [String: Any]) throws {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0).write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        for directory in [Self.folder] where !FileManager.default.fileExists(atPath: directory.path) {
            try sudo("/usr/bin/install", "-d", "-o", "root", "-g", "wheel", "-m", "0755", directory.path)
            createdFolders.insert(directory, at: 0)
        }
        try sudo("/usr/bin/install", "-o", "root", "-g", "wheel", "-m", "0644", staged.path, file.path)
        reloadPreferences()
    }

    nonisolated static func removeProfile() throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try sudo("/bin/rm", "-f", file.path)
            reloadPreferences()
        }
        for folder in createdFolders { _ = run("/usr/bin/sudo", ["-n", "/bin/rmdir", folder.path]) }
        createdFolders = []
    }

    /// cfprefsd keeps managed preferences cached; restarting the person's and the system's makes
    /// them read the files again.
    nonisolated static func reloadPreferences() {
        run("/usr/bin/killall", ["cfprefsd"])
        run("/usr/bin/sudo", ["-n", "/usr/bin/killall", "cfprefsd"])
    }

    @discardableResult nonisolated static func sudo(_ arguments: String...) throws -> String {
        let result = run("/usr/bin/sudo", ["-n"] + arguments)
        guard result.status == 0 else {
            throw Failure("sudo \(arguments.joined(separator: " ")) failed with \(result.status): \(result.output)")
        }
        return result.output
    }

    @discardableResult nonisolated static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
