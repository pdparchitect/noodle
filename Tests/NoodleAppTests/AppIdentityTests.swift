import XCTest
@testable import Noodle

final class AppIdentityTests: XCTestCase {
    /// Development-only menus must never reach the production bundle.
    func testOnlyTheLocalBundleAndUnbundledRunsAreDevelopment() {
        XCTAssertTrue(NoodleAppIdentity.isDevelopment(bundleIdentifier: "com.pdparchitect.noodle.local"))
        XCTAssertTrue(NoodleAppIdentity.isDevelopment(bundleIdentifier: nil))
        XCTAssertFalse(NoodleAppIdentity.isDevelopment(bundleIdentifier: "com.pdparchitect.noodle"))
        XCTAssertFalse(NoodleAppIdentity.isDevelopment(bundleIdentifier: "com.pdparchitect.noodle.localhost"))
    }

    /// The bots that are given a calendar or a reminder list reach EventKit from the sandboxed
    /// app, which needs one entitlement per kind: without them the access request is denied
    /// without ever asking the person.
    func testSandboxPolicyGrantsBothCalendarsAndReminders() throws {
        let keys = try Set(Self.sandboxPolicy().keys)
        XCTAssertTrue(keys.contains("com.apple.security.personal-information.calendars"))
        XCTAssertTrue(keys.contains("com.apple.security.personal-information.reminders"))
    }

    /// Release packaging and the smoke test pin how many entitlements the reviewed policy has, so
    /// an unreviewed one cannot ship. Both pins have to follow the policy when it changes.
    func testReleaseVerifiersPinTheNumberOfEntitlementsThePolicyHas() throws {
        let expected = try Self.sandboxPolicy().count
        for script in ["scripts/package-release.sh", "Tests/smoke-test.sh"] {
            let text = try String(contentsOf: Self.repository.appendingPathComponent(script), encoding: .utf8)
            let pinned = text
                .components(separatedBy: "entitlement_count\" != \"")
                .dropFirst()
                .compactMap { Int($0.prefix(while: { $0.isNumber })) }
            XCTAssertEqual(pinned, [expected], script)
        }
    }

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func sandboxPolicy() throws -> [String: Any] {
        let data = try Data(contentsOf: repository.appendingPathComponent("Support/Noodle.entitlements"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}
