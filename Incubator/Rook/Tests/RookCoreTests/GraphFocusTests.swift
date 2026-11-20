import Foundation
import RookCore
import XCTest

final class GraphFocusTests: XCTestCase {
    func testFocusIncludesOnlyImmediateNeighboursInEitherDirection() throws {
        var record = CaseRecord()
        let actor = CaseActor.champion("Investigator")
        let now = Date(timeIntervalSince1970: 0)
        let nodes = (0..<4).map { record.record(entity: .host, name: "Host \($0)", detail: nil, by: actor, at: now) }
        try record.record(linkFrom: nodes[0].id, relation: "reaches", to: nodes[1].id, by: actor, at: now)
        try record.record(linkFrom: nodes[2].id, relation: "reaches", to: nodes[0].id, by: actor, at: now)
        try record.record(linkFrom: nodes[1].id, relation: "reaches", to: nodes[3].id, by: actor, at: now)
        XCTAssertEqual(record.graphFocus(around: nodes[0].id), Set(nodes.prefix(3).map(\.id)))
        XCTAssertEqual(record.graphFocus(around: nil), Set(nodes.map(\.id)))
        XCTAssertEqual(record.graphFocus(around: "deleted"), Set(nodes.map(\.id)))
    }
}
