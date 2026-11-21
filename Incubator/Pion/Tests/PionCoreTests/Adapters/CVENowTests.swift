import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class CVENowTests: XCTestCase {
    /// A `rankings.get` answer as cve.now's MCP server gives it, cut to what the trigger reads.
    static func ranking(_ ids: [String]) -> Data {
        let rows = ids.enumerated().map { ["rank": $0.offset + 1, "id": $0.element, "score": 90] as [String: Any] }
        let board: [String: Any] = ["id": "cves", "period": "7d", "generatedAt": "2026-11-19T23:51:33.023Z", "rows": rows]
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: board), as: UTF8.self)
        return try! JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": text], ["type": "text", "text": "Source: cve.now"]],
            "structuredContent": board,
        ] as [String: Any])
    }

    func testTheTriggerReadsTheTop10OfTheWeeksIndex() throws {
        let trigger = CVENow.trigger
        XCTAssertEqual(trigger.tool, "execute")
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: trigger.arguments) as? [String: Any])
        XCTAssertEqual(arguments["name"] as? String, "rankings.get")
        XCTAssertEqual(arguments["arguments"] as? [String: AnyHashable], ["id": "cves", "period": "7d", "limit": 10])
        XCTAssertEqual(trigger.interval, 3_600)
        XCTAssertEqual(try trigger.entries(Self.ranking(["CVE-2026-42208", "CVE-2026-39808"])), ["CVE-2026-42208", "CVE-2026-39808"])
    }

    /// Without structured content, the board is read from the text the server sends, as an older server sends it.
    func testTheBoardIsReadFromItsTextWhenItHasNoStructuredContent() throws {
        let board = #"{"id":"cves","rows":[{"rank":1,"id":"CVE-2025-24016"}]}"#
        let result = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": board]]])
        XCTAssertEqual(try CVENow.trigger.entries(result), ["CVE-2025-24016"])
    }

    func testARefusedOrUnreadableBoardIsAFailure() {
        let refused = Data(#"{"content":[{"type":"text","text":"not_found"}],"isError":true}"#.utf8)
        XCTAssertThrowsError(try CVENow.trigger.entries(refused))
        XCTAssertThrowsError(try CVENow.trigger.entries(Data(#"{"content":[{"type":"text","text":"no board"}]}"#.utf8)))
    }

    /// Only IDs go into the note that wakes the agents, never anything else the server sends.
    func testOnlyEntryIDsAreTaken() throws {
        let rows: [[String: Any]] = [["id": "CVE-2026-1"], ["id": "\" /><evil"], ["id": String(repeating: "A", count: 100)], ["rank": 4]]
        let result = try JSONSerialization.data(withJSONObject: ["structuredContent": ["rows": rows]])
        XCTAssertEqual(try CVENow.trigger.entries(result), ["CVE-2026-1"])
    }

    @MainActor func testItIsOfferedOpenAndWatched() throws {
        let entry = try XCTUnwrap(PionCatalogue.entries.first { $0.name == "cve.now" })
        let account = try entry.makeConnection(name: "cve.now")
        XCTAssertEqual(account.open, true, "It needs no sign-in")
        let watcher = AlertWatcher(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), alerts: { _, _ in [] })
        watcher.triggers = PionCatalogue.triggers
        XCTAssertTrue(watcher.watches(account))
        let skill = try XCTUnwrap(watcher.skillText(for: account))
        XCTAssertTrue(skill.contains("<tool-alerts"), skill)
        XCTAssertTrue(skill.contains("`rankings.get`"), skill)
    }
}
