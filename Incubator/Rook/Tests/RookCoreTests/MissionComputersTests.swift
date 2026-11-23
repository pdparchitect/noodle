import Foundation
@testable import RookCore
import XCTest

final class MissionComputersTests: XCTestCase {
    private var root: URL!
    private var store: RookStore!
    private let linux = UUID(), jumpBox = UUID()
    private let lead = UUID(), analyst = UUID(), outsider = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MissionComputersTests-\(UUID().uuidString)", isDirectory: true)
        store = RookStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func open(_ title: String = "Beaconing laptop") throws -> Mission {
        try store.open(id: UUID(), title: title, objective: "Find out why LT-0423 beacons", champion: "Avery")
    }

    func testOnlyTheChampionAssignsComputersAndEachChangeIsAudited() throws {
        let mission = try open()
        XCTAssertThrowsError(try store.setComputer(linux, named: "Linux", assigned: true, in: mission.id, by: .agent(lead)))
        try store.setComputer(linux, named: "Linux", assigned: true, in: mission.id, by: .champion("Avery"))
        try store.setComputer(jumpBox, named: "Jump box", assigned: true, in: mission.id, by: .champion("Avery"))
        try store.setComputer(linux, named: "Linux", assigned: true, in: mission.id, by: .champion("Avery"))
        XCTAssertEqual(store.mission(mission.id)?.computers, [linux, jumpBox])
        try store.setComputer(linux, named: "Linux", assigned: false, in: mission.id, by: .champion("Avery"))
        XCTAssertEqual(store.mission(mission.id)?.computers, [jumpBox])
        XCTAssertEqual(store.audit(mission.id).filter { $0.event == "computer" }.map(\.detail),
                       ["Added Linux.", "Added Jump box.", "Removed Linux."])
    }

    func testAMissionSavedBeforeComputersHasNone() throws {
        let mission = try open()
        let url = store.folder(mission.id).appendingPathComponent("mission.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["computerIDs"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertEqual(store.mission(mission.id)?.computers, [])
    }

    /// One computer may serve several Missions; an agent reaches it while they share one that is not closed.
    func testAgentsReachTheComputersOfOpenMissionsTheyAreIn() throws {
        let first = try open(), second = try open("Phishing kit"), closed = try open("Old case")
        try store.setComputer(linux, named: "Linux", assigned: true, in: first.id, by: .champion("Avery"))
        try store.setComputer(linux, named: "Linux", assigned: true, in: second.id, by: .champion("Avery"))
        try store.setComputer(jumpBox, named: "Jump box", assigned: true, in: second.id, by: .champion("Avery"))
        try store.setComputer(jumpBox, named: "Jump box", assigned: true, in: closed.id, by: .champion("Avery"))
        try store.setStatus(.closed, of: closed.id, by: .champion("Avery"), outcome: .reported)
        let members: [UUID: [UUID]] = [first.id: [lead, analyst], second.id: [lead], closed.id: [outsider]]
        let access = MissionComputers.assignments(missions: store.missions()) { members[$0] ?? [] }
        XCTAssertEqual(access[lead], [linux.uuidString, jumpBox.uuidString])
        XCTAssertEqual(access[analyst], [linux.uuidString])
        XCTAssertNil(access[outsider])
    }

    func testForgettingAComputerTakesItOutOfEveryMission() throws {
        let first = try open(), second = try open("Phishing kit")
        for mission in [first, second] {
            try store.setComputer(linux, named: "Linux", assigned: true, in: mission.id, by: .champion("Avery"))
        }
        try store.forgetComputer(linux, named: "Linux", by: .champion("Avery"))
        XCTAssertEqual(store.missions().flatMap(\.computers), [])
        XCTAssertEqual(store.audit(first.id).last?.detail, "Removed Linux, which was deleted.")
    }
}
