import Foundation
import XCTest
@testable import LocalMacCore

final class PermissionHelperTests: XCTestCase {
    func testUnknownOrTestProviderCannotStagePermissionHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for id in ["unknown", "com.pdparchitect.noodle.computer.tests"] {
            XCTAssertThrowsError(try LocalMacPermissionHelper.prepare(source: root, directory: root,
                providerID: id, team: "S8VNVK39LH"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// Opt-in integration check against a real signed bundle. Copies only into
    /// a temporary directory; it never launches the helper or alters consent.
    func testSignedCopyIsStandaloneUnmodifiedAndBuildSpecific() throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_PERMISSION_HELPER_FIXTURE"] else {
            throw XCTSkip("Set NOODLE_PERMISSION_HELPER_FIXTURE to a signed Computer app for this integration check.")
        }
        let app = URL(fileURLWithPath: path), bundle = try XCTUnwrap(Bundle(url: app))
        let provider = try XCTUnwrap(bundle.bundleIdentifier)
        let team = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String)
        let identity = try XCTUnwrap(LocalMacIdentity(providerID: provider))
        let source = app.appendingPathComponent("Contents/Helpers/LocalMacDesktop.app")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Permissions")
        let destination = try LocalMacPermissionHelper.prepare(source: source, directory: directory, providerID: provider, team: team)
        XCTAssertEqual(destination.lastPathComponent, identity.desktopAppName + ".app")
        XCTAssertEqual(Bundle(url: destination)?.bundleIdentifier, identity.desktopID)
        let requirement = "anchor apple generic and identifier \"\(identity.desktopID)\" and certificate leaf[subject.OU] = \"\(team)\""
        XCTAssertEqual(try LocalMacSignedCode.fingerprint(at: source, requirement: requirement),
                       try LocalMacSignedCode.fingerprint(at: destination, requirement: requirement))
        let sentinel = root.appendingPathComponent("retained")
        try Data("preserve".utf8).write(to: sentinel)
        XCTAssertEqual(try LocalMacPermissionHelper.prepare(source: source, directory: directory, providerID: provider, team: team), destination)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
        let otherProvider = provider.hasSuffix(".local") ? "com.pdparchitect.noodle.computer" : "com.pdparchitect.noodle.computer.local"
        XCTAssertThrowsError(try LocalMacPermissionHelper.prepare(source: source, directory: directory, providerID: otherProvider, team: team))
        XCTAssertThrowsError(try LocalMacPermissionHelper.prepare(source: source, directory: root.appendingPathComponent("Nested.app/Helpers"), providerID: provider, team: team))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertThrowsError(try LocalMacPermissionHelper.prepare(source: source, directory: alias, providerID: provider, team: team))
    }
}
