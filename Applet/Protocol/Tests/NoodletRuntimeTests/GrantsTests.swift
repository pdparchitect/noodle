import XCTest
@testable import NoodletRuntime

/// A Hub's noodlet asks once on each device for what it declares, and keeps the answer until
/// the person takes it back.
final class GrantsTests: XCTestCase {
    private func grants() -> NoodletGrants {
        let suite = "NoodletGrants." + UUID().uuidString
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return NoodletGrants(defaults: UserDefaults(suiteName: suite)!)
    }

    private func manifest(_ permissions: [String]?) -> NoodletManifest {
        var manifest = NoodletManifest(title: "Remote")
        manifest.permissions = permissions
        return manifest
    }

    func testANoodletThatDeclaresNothingIsNeverAsked() {
        XCTAssertFalse(grants().needsAsking(manifest(nil), id: UUID()))
        XCTAssertFalse(grants().needsAsking(manifest([]), id: UUID()))
    }

    func testAllowedOnceItIsNotAskedAgainUntilTakenBack() {
        let grants = grants(), id = UUID()
        XCTAssertTrue(grants.needsAsking(manifest(["local-network"]), id: id))
        grants.allow(manifest(["local-network"]), id: id)
        XCTAssertFalse(grants.needsAsking(manifest(["local-network"]), id: id))
        XCTAssertEqual(grants.all, [NoodletGrants.Grant(id: id, title: "Remote", permissions: ["local-network"])])
        grants.revoke(id)
        XCTAssertTrue(grants.needsAsking(manifest(["local-network"]), id: id))
        XCTAssertEqual(grants.all, [])
    }

    /// A new version that asks for more asks again, for all of it.
    func testAskingForMoreAsksAgain() {
        let grants = grants(), id = UUID()
        grants.allow(manifest(["camera"]), id: id)
        XCTAssertTrue(grants.needsAsking(manifest(["camera", "local-network"]), id: id))
        XCTAssertTrue(grants.needsAsking(manifest(["camera"]), id: UUID()), "each noodlet is asked for itself")
    }

    func testTheQuestionAndRefusalNameWhatItWants() {
        XCTAssertEqual(NoodletGrants.question(manifest(["local-network", "camera"])),
                       "“Remote” would like to use the camera and devices on your local network.")
        XCTAssertEqual(NoodletGrants.refusal(manifest(["local-network"])),
                       "Permission was not given to use devices on your local network.")
        XCTAssertEqual(NoodletManifest.permissionTitles["local-network"], "Local Network")
    }
}
