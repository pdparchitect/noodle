import CoreServices
import Foundation
import HubCore
import HubLink
import HubMac
import XCTest

/// Quitting the Hub cuts off whoever is connected and stops its bots, so it asks first.
final class HubQuitTests: XCTestCase {
    func testTheQuestionSaysWhoAndWhatQuittingInterrupts() {
        XCTAssertNil(HubActivity(people: 0, devices: 0, workingBots: 0).interruption)
        XCTAssertEqual(HubActivity(people: 1, devices: 1, workingBots: 0).interruption,
                       "1 person on 1 device is connected.")
        XCTAssertEqual(HubActivity(people: 2, devices: 3, workingBots: 0).interruption,
                       "2 people on 3 devices are connected.")
        XCTAssertEqual(HubActivity(people: 0, devices: 0, workingBots: 1).interruption, "1 bot is working.")
        XCTAssertEqual(HubActivity(people: 2, devices: 2, workingBots: 3).interruption,
                       "2 people on 2 devices are connected, and 3 bots are working.")
    }

    func testLoggingOutRestartingAndShuttingDownDoNotAsk() {
        XCTAssertTrue(HubQuit.asksFirst(quitReason: nil))
        for reason in [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog,
                       kAERestart, kAEShutDown] {
            XCTAssertFalse(HubQuit.asksFirst(quitReason: OSType(reason)), "\(reason)")
        }
    }

    @MainActor func testTheHubCountsConnectedDevicesAndTheirPeople() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-quit-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root, messenger: nil)
        XCTAssertEqual(hub.activity, HubActivity(people: 0, devices: 0, workingBots: 0))
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.addDevice(named: "iPhone", key: LinkIdentity().publicKey, for: ada, at: Date())
        hub.access.addDevice(named: "iPad", key: LinkIdentity().publicKey, for: ada, at: Date())
        hub.access.addDevice(named: "Old", key: LinkIdentity().publicKey, for: ada, at: .distantPast)
        XCTAssertEqual(hub.activity, HubActivity(people: 1, devices: 2, workingBots: 0))
    }
}
