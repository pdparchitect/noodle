import Foundation
@testable import HubCore
import HubLink
import NoodleCore
import XCTest

/// The Hub's record of who changed its users and devices, and who tried to and was refused.
@MainActor final class HubActivityLogTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-activity-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func log(at url: URL, limit: Int = 10_000) -> HubActivityLog {
        HubActivityLog(url: url.appendingPathComponent("activity.jsonl"), now: { [unowned self] in clock }, limit: limit)
    }

    private func access(at url: URL) -> HubAccess {
        let access = HubAccess(url: url.appendingPathComponent("access.json"))
        access.log = log(at: url)
        return access
    }

    private func whats(_ access: HubAccess) -> [String] { access.log?.entries.map(\.what) ?? [] }

    // MARK: The log itself

    func testEntriesSurviveARelaunchInOrder() {
        let url = folder()
        let ada = UUID()
        log(at: url).record(who: "This Mac", what: "Added Ada", users: [ada])
        clock += 60
        log(at: url).record(who: "This Mac", what: "Removed Ada", refusal: "No.", users: [ada])
        let reopened = log(at: url)
        XCTAssertEqual(reopened.entries.map(\.what), ["Added Ada", "Removed Ada"])
        XCTAssertEqual(reopened.entries.map(\.date), [clock - 60, clock])
        XCTAssertEqual(reopened.entries.last?.refusal, "No.")
        XCTAssertEqual(reopened.entries.last?.users, [ada])
        XCTAssertEqual(reopened.entries.last?.who, "This Mac")
    }

    func testEntriesOlderThanNinetyDaysAreDropped() {
        let url = folder()
        let first = log(at: url)
        first.record(who: "This Mac", what: "Old", users: [])
        clock += HubActivityLog.retention / 2
        first.record(who: "This Mac", what: "Middle", users: [])
        clock += HubActivityLog.retention / 2 + 1
        first.record(who: "This Mac", what: "New", users: [])
        XCTAssertEqual(first.entries.map(\.what), ["Middle", "New"])
        // Gone from the file too, and dropped again on opening once they age.
        XCTAssertEqual(log(at: url).entries.map(\.what), ["Middle", "New"])
        clock += HubActivityLog.retention / 2
        XCTAssertEqual(log(at: url).entries.map(\.what), ["New"])
    }

    /// A device sending refused requests cannot grow the log without end.
    func testTheLogKeepsOnlyTheNewestEntries() {
        let url = folder()
        XCTAssertEqual(HubActivityLog(url: url.appendingPathComponent("other.jsonl")).limit, 10_000)
        let first = log(at: url, limit: 20)
        for index in 0..<25 { first.record(who: "x", what: "\(index)", users: []) }
        XCTAssertEqual(first.entries.map(\.what), (5..<25).map(String.init))
        XCTAssertEqual(log(at: url, limit: 20).entries.map(\.what), (5..<25).map(String.init))
        // Opening with a smaller limit drops the oldest too.
        XCTAssertEqual(log(at: url, limit: 10).entries.map(\.what), (15..<25).map(String.init))
    }

    func testALineThatCannotBeReadIsSkipped() throws {
        let url = folder()
        log(at: url).record(who: "This Mac", what: "Added Ada", users: [])
        let file = url.appendingPathComponent("activity.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        log(at: url).record(who: "This Mac", what: "Added Bea", users: [])
        XCTAssertEqual(log(at: url).entries.map(\.what), ["Added Ada", "Added Bea"])
    }

    func testEntriesAboutSomeone() {
        let url = folder()
        let log = log(at: url)
        let ada = UUID(), bea = UUID()
        log.record(who: "This Mac", what: "Added Ada", users: [ada])
        log.record(who: "This Mac", what: "Added Bea", users: [bea])
        log.record(who: "Ada on iPhone", what: "Removed Bea", users: [ada, bea])
        XCTAssertEqual(log.entries(about: ada).map(\.what), ["Added Ada", "Removed Bea"])
        XCTAssertEqual(log.entries(about: nil).map(\.what), ["Added Ada", "Added Bea", "Removed Bea"])
    }

    // MARK: What the Hub's own Settings change

    func testChangesOnTheHubAreLoggedAsThisMac() throws {
        let access = access(at: folder())
        let family = try access.addPlan(named: "Family")
        let ada = try access.addUser(named: "Ada")
        try access.rename(ada, to: "Ada L.")
        access.move(ada, to: family)
        access.setCanPairDevices(false, for: ada)
        access.setCanPairDevices(true, for: ada)
        access.setAdmin(true, for: ada)
        access.setAdmin(false, for: ada)
        let device = access.addDevice(named: "Ada’s iPhone", key: LinkIdentity().publicKey, for: ada, at: clock)
        access.remove(device)
        access.remove(ada)
        XCTAssertEqual(whats(access), [
            "Added Ada", "Renamed Ada to Ada L.", "Moved Ada L. to the Family plan",
            "Stopped Ada L. pairing devices", "Let Ada L. pair devices",
            "Made Ada L. an admin", "Made Ada L. no longer an admin",
            "Paired “Ada’s iPhone” for Ada L.", "Unpaired “Ada’s iPhone” from Ada L.", "Removed Ada L.",
        ])
        XCTAssertEqual(Set(access.log?.entries.map(\.who) ?? []), ["This Mac"])
        XCTAssertEqual(Set(access.log?.entries.flatMap(\.users) ?? []), [ada.id])
        XCTAssertEqual(access.log?.entries.allSatisfy { $0.refusal == nil }, true)
    }

    /// Settings sets values it already has, as a switch redrawn does; only changes are kept.
    func testChangesThatChangeNothingAreNotLogged() throws {
        let access = access(at: folder())
        let ada = try access.addUser(named: "Ada")
        try access.rename(ada, to: "Ada")
        access.move(ada, to: try XCTUnwrap(access.plans.first))
        access.setCanPairDevices(true, for: ada)
        access.setAdmin(false, for: ada)
        access.remove(HubDevice(user: ada.id, name: "Ghost", key: LinkIdentity().publicKey, paired: clock))
        access.remove(HubUser(name: "Ghost"))
        XCTAssertEqual(whats(access), ["Added Ada"])
    }

    func testChangesAreLoggedAsWhoeverActs() throws {
        let access = access(at: folder())
        let grace = try access.addUser(named: "Grace")
        let actor = HubActor(who: "Grace on Grace’s iPhone", user: grace.id)
        let ada = try access.acting(as: actor) { try access.addUser(named: "Ada") }
        try access.rename(ada, to: "Ada L.")
        let last = try XCTUnwrap(access.log?.entries.suffix(2))
        XCTAssertEqual(last.map(\.who), ["Grace on Grace’s iPhone", "This Mac"])
        XCTAssertEqual(last.first?.users, [grace.id, ada.id])
    }

    /// Without a log, as on This Mac as a Hub, nothing is kept.
    func testAccessWithoutALogKeepsNothing() throws {
        let url = folder()
        let access = HubAccess(url: url.appendingPathComponent("access.json"))
        _ = try access.addUser(named: "Ada")
        XCTAssertNil(access.log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("activity.jsonl").path))
    }

    func testTheHubKeepsALog() throws {
        let root = folder()
        let hub = Hub(root: root, messenger: nil)
        _ = try hub.access.addUser(named: "Ada")
        XCTAssertEqual(hub.access.log?.entries.map(\.what), ["Added Ada"])
        XCTAssertEqual(HubActivityLog(url: root.appendingPathComponent("activity.jsonl")).entries.map(\.what), ["Added Ada"])
    }
}
