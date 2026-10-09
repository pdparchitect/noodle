import CloudKit
import Foundation
@testable import HubLink
import XCTest

/// The spaces a person makes, which every device shows the same, kept in one file per device.
@MainActor final class SpaceListTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceListTests-\(UUID())/spaces.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testSpacesKeepTheirMembersAndPinsInOrder() throws {
        let list = SpaceList(file: file)
        XCTAssertTrue(list.spaces.isEmpty)
        let work = try list.add(named: "  Work ")
        XCTAssertEqual(work.name, "Work")
        let scout = CustomSpace.Member(hub: "studio", conversation: UUID())
        let atlas = CustomSpace.Member(hub: nil, conversation: UUID())

        try list.setMember(true, scout, of: work.id)
        try list.setMember(true, atlas, of: work.id)
        try list.setMember(true, scout, of: work.id)
        XCTAssertEqual(list.space(work.id)?.members, [scout, atlas])

        try list.setPinned(true, atlas, in: work.id)
        try list.setPinned(true, scout, in: work.id)
        XCTAssertEqual(list.space(work.id)?.pins, [atlas, scout])
        try list.rename(work.id, to: "Projects")

        // Leaving a space drops its pin there too.
        try list.setMember(false, atlas, of: work.id)
        XCTAssertEqual(list.space(work.id)?.members, [scout])
        XCTAssertEqual(list.space(work.id)?.pins, [scout])

        let again = SpaceList(file: file)
        XCTAssertEqual(again.spaces, [CustomSpace(id: work.id, name: "Projects", members: [scout], pins: [scout], position: 1)])
        try again.delete(work.id)
        XCTAssertTrue(SpaceList(file: file).spaces.isEmpty)
    }

    /// Only members are pinned.
    func testPinningAddsNoMember() throws {
        let list = SpaceList(file: file)
        let work = try list.add(named: "Work")
        try list.setPinned(true, CustomSpace.Member(hub: nil, conversation: UUID()), in: work.id)
        XCTAssertEqual(list.space(work.id)?.pins, [])
    }

    /// Edits made here are handed on for iCloud; those from iCloud are kept without being sent back.
    func testEditsHereAreSentOnAndThoseFromOtherDevicesAreNot() throws {
        let list = SpaceList(file: file)
        var sent: [([UUID], [UUID])] = []
        list.onChange = { sent.append(($0, $1)) }
        let work = try list.add(named: "Work")
        try list.rename(work.id, to: "Projects")
        try list.delete(work.id)
        XCTAssertEqual(sent.map(\.0), [[work.id], [work.id], []])
        XCTAssertEqual(sent.map(\.1), [[], [], [work.id]])

        sent = []
        let home = CustomSpace(name: "Home", members: [CustomSpace.Member(hub: "studio", conversation: UUID())])
        let errands = CustomSpace(name: "errands")
        list.applyRemote(saved: [home, errands], deleted: [])
        // By name, the same on every device.
        XCTAssertEqual(list.spaces, [errands, home])
        var renamed = home
        renamed.name = "Family"
        list.applyRemote(saved: [renamed], deleted: [errands.id])
        XCTAssertEqual(list.spaces, [renamed])
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(SpaceList(file: file).spaces, [renamed])
    }

    /// The person's own order, the same on every device: new spaces go last, and a move sends only the space moved.
    func testSpacesKeepThePersonsOrder() throws {
        let list = SpaceList(file: file)
        let work = try list.add(named: "Work")
        let home = try list.add(named: "Home")
        let errands = try list.add(named: "Errands")
        XCTAssertEqual(list.spaces.map(\.name), ["Work", "Home", "Errands"])

        var sent: [[UUID]] = []
        list.onChange = { saved, _ in sent.append(saved) }
        try list.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(list.spaces.map(\.name), ["Errands", "Work", "Home"])
        try list.move(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        XCTAssertEqual(list.spaces.map(\.name), ["Errands", "Home", "Work"])
        XCTAssertEqual(sent, [[errands.id], [work.id]])
        XCTAssertEqual(SpaceList(file: file).spaces.map(\.id), [errands.id, home.id, work.id])

        // Another device's move arrives as that space's new place.
        var moved = try XCTUnwrap(list.space(work.id))
        moved.position = -1
        list.applyRemote(saved: [moved], deleted: [])
        XCTAssertEqual(list.spaces.map(\.name), ["Work", "Errands", "Home"])
    }

    /// Spaces from before there was an order come first, by name, and are all given places once one is moved.
    func testSpacesWithoutAPlaceAreGivenOneWhenMoved() throws {
        let list = SpaceList(file: file)
        let home = CustomSpace(name: "Home")
        let errands = CustomSpace(name: "errands")
        list.applyRemote(saved: [home, errands], deleted: [])
        let work = try list.add(named: "Work")
        XCTAssertEqual(list.spaces.map(\.name), ["errands", "Home", "Work"])

        var sent: [[UUID]] = []
        list.onChange = { saved, _ in sent.append(saved) }
        try list.move(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        XCTAssertEqual(list.spaces.map(\.name), ["errands", "Work", "Home"])
        XCTAssertEqual(sent.map(Set.init), [[errands.id, work.id, home.id]])
        XCTAssertTrue(list.spaces.allSatisfy { $0.position != nil })
    }

    /// One record per space in the private database, its contents encrypted.
    func testASpaceRoundTripsThroughItsRecord() throws {
        let member = CustomSpace.Member(hub: "studio", conversation: UUID())
        let space = CustomSpace(name: "Work", members: [member, CustomSpace.Member(hub: nil, conversation: UUID())], pins: [member],
                                position: 2.5)
        let record = SpaceRecords.record(for: space, systemFields: nil)
        XCTAssertEqual(record.recordID, SpaceRecords.recordID(for: space.id))
        XCTAssertEqual(record.recordID.zoneID, SpaceRecords.zoneID)
        XCTAssertEqual(record.recordType, SpaceRecords.recordType)
        XCTAssertNil(record["name"])
        XCTAssertEqual(SpaceRecords.space(from: record), space)
        XCTAssertEqual(SpaceRecords.space(from: SpaceRecords.record(for: CustomSpace(name: "Home"), systemFields: nil))?.position, nil)

        // Saved again over what iCloud last returned, so it is a change rather than a conflict.
        let fields = SpaceRecords.systemFields(of: record)
        var renamed = space
        renamed.name = "Projects"
        let again = SpaceRecords.record(for: renamed, systemFields: fields)
        XCTAssertEqual(again.recordID, record.recordID)
        XCTAssertEqual(SpaceRecords.space(from: again)?.name, "Projects")
    }
}
