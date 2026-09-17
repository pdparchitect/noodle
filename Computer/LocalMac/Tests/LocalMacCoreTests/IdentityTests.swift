import XCTest
@testable import LocalMacCore

final class IdentityTests: XCTestCase {
    func testDevelopmentCannotReachProductionServiceOrRecords() throws {
        let release = try XCTUnwrap(LocalMacIdentity(providerID: "com.pdparchitect.noodle.computer"))
        let local = try XCTUnwrap(LocalMacIdentity(providerID: "com.pdparchitect.noodle.computer.local"))
        XCTAssertEqual(release.storageDirectory.path, "/Library/Application Support/Noodle Computer/Local Mac")
        XCTAssertEqual(local.storageDirectory.path, "/Library/Application Support/Noodle Computer Local/Local Mac")
        XCTAssertNotEqual(release.serviceID, local.serviceID) // Also the System keychain service key.
        XCTAssertNotEqual(release.group(team: "ABCDEFGHIJ"), local.group(team: "ABCDEFGHIJ"))
        XCTAssertNotEqual(release.daemonPlist, local.daemonPlist)
        XCTAssertNotEqual(release.desktopID, local.desktopID)
        XCTAssertNotEqual(release.desktopAppName, local.desktopAppName)
        XCTAssertEqual(release.setupAppName, "Noodle Computer Setup")
        XCTAssertEqual(local.setupAppName, "Noodle Computer Dev Setup")
        for identity in [release, local] {
            XCTAssertTrue(identity.permitsAccountService)
            XCTAssertEqual(LocalMacIdentity.setup(identity.setupID), identity)
            XCTAssertEqual(LocalMacIdentity.desktop(identity.desktopID), identity)
        }
    }
    func testFixturesAndUnknownIdentitiesCannotRegisterAccounts() throws {
        let test = try XCTUnwrap(LocalMacIdentity(providerID: "com.pdparchitect.noodle.computer.tests"))
        XCTAssertFalse(test.permitsAccountService)
        XCTAssertNil(LocalMacIdentity(providerID: "com.pdparchitect.noodle.local"))
        XCTAssertNil(LocalMacIdentity.setup("com.pdparchitect.noodle.computer.localmacsetup.forged"))
        XCTAssertNil(LocalMacIdentity.desktop(nil))
    }
}
