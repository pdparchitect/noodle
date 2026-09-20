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
}
