import Foundation
import HubCore
import HubMac
import XCTest

/// The Hub is server software, so it opens at login unless its owner turned that off.
final class HubLoginItemTests: XCTestCase {
    func testTheHubRegistersOnceAndThenLeavesTheChoiceToItsOwner() {
        let defaults = UserDefaults(suiteName: "noodle-hub-login-\(UUID())")!
        var registrations = 0
        HubLoginItem.registerByDefault(defaults: defaults) { registrations += 1 }
        XCTAssertEqual(registrations, 1)
        // Turned off in Settings or Login Items: later launches do not turn it back on.
        HubLoginItem.registerByDefault(defaults: defaults) { registrations += 1 }
        XCTAssertEqual(registrations, 1)
    }

    func testAFailedRegistrationIsTriedAgainNextLaunch() {
        let defaults = UserDefaults(suiteName: "noodle-hub-login-\(UUID())")!
        var attempts = 0
        HubLoginItem.registerByDefault(defaults: defaults) { attempts += 1; throw CocoaError(.featureUnsupported) }
        HubLoginItem.registerByDefault(defaults: defaults) { attempts += 1 }
        HubLoginItem.registerByDefault(defaults: defaults) { attempts += 1 }
        XCTAssertEqual(attempts, 2)
    }
}
