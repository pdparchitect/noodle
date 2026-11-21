import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

/// Pion's adapters and cve.now's board, watched by the watcher every app runs.
final class AlertWatchTests: XCTestCase {
    @MainActor func testTheWatcherWakesEachAgentAnAccountIsAssignedToAndSaysWhatEachCheckFound() async throws {
        let defender = try Defender.preset.makeConnection(name: "Defender — Contoso", values: ["tenant": "contoso.onmicrosoft.com"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let raised = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        let service = FakeService()
        service.answers["/v1.0/security/alerts_v2"] = (200, #"{"value":[{"id":"a1","createdDateTime":"\#(raised)"}]}"#)
        let watcher = AlertWatcher(file: file, alerts: { connection, since in
            try await Defender.adapter.alerts(since: since, connection: connection, access: service)
        })
        watcher.adapters = PionAdapters.all
        let (lead, analyst) = (UUID(), UUID())
        var woken: [(UUID, String)] = []

        var checked = await watcher.check([(defender, [lead, analyst])], keeping: [], at: now) { woken.append(($0, $1)) }
        XCTAssertEqual(checked, [defender.id: .started], "The first check only marks where watching starts")
        XCTAssertTrue(woken.isEmpty)
        checked = await watcher.check([(defender, [lead, analyst])], keeping: [], at: now.addingTimeInterval(300)) { woken.append(($0, $1)) }
        XCTAssertEqual(checked, [defender.id: .found("1 new alert")])
        XCTAssertEqual(woken.map(\.0), [lead, analyst])
        XCTAssertTrue(woken.allSatisfy { $0.1.contains(#"new="1""#) && $0.1.contains(#"tool="alerts""#) }, "\(woken)")
        checked = await watcher.check([(defender, [lead, analyst])], keeping: [], at: now.addingTimeInterval(450)) { woken.append(($0, $1)) }
        XCTAssertEqual(checked, [defender.id: .nothingNew])

        service.answers["/v1.0/security/alerts_v2"] = (403, #"{"error":{"code":"Forbidden","message":"Missing role permissions."}}"#)
        checked = await watcher.check([(defender, [lead])], keeping: [], at: now.addingTimeInterval(600)) { woken.append(($0, $1)) }
        guard case .failed? = checked[defender.id] else { return XCTFail("\(checked)") }
        XCTAssertEqual(woken.count, 2, "A failed check wakes no one")
    }

    /// cve.now's board is read through its MCP server once an hour, and wakes the agents for CVEs newly on it.
    @MainActor func testTheWatcherReadsAnMCPServersBoardHourlyAndWakesForWhatIsNew() async throws {
        let entry = try XCTUnwrap(PionCatalogue.entries.first { $0.name == "cve.now" })
        let cve = try entry.makeConnection(name: "cve.now")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let board = Board()
        let watcher = AlertWatcher(file: file, alerts: { _, _ in [] }) { connection, request in
            XCTAssertEqual(connection.id, cve.id)
            XCTAssertEqual(request.action, .call)
            XCTAssertEqual(request.tool, "execute")
            return try board.answer()
        }
        watcher.triggers = PionCatalogue.triggers
        let lead = UUID()
        var woken: [(UUID, String)] = []
        let now = Date()

        board.ids = ["CVE-2026-1", "CVE-2026-2"]
        var checked = await watcher.check([(cve, [lead])], keeping: [], at: now) { woken.append(($0, $1)) }
        XCTAssertEqual(checked, [cve.id: .nothingNew], "The first read only notes what is on it")
        XCTAssertTrue(woken.isEmpty)
        board.ids = ["CVE-2026-3", "CVE-2026-1", "CVE-2026-2"]
        checked = await watcher.check([(cve, [lead])], keeping: [], at: now.addingTimeInterval(300)) { woken.append(($0, $1)) }
        XCTAssertTrue(checked.isEmpty && woken.isEmpty, "Not read again within the hour")
        XCTAssertEqual(board.reads, 1)
        checked = await watcher.check([(cve, [lead])], keeping: [], at: now.addingTimeInterval(3_600)) { woken.append(($0, $1)) }
        XCTAssertEqual(checked, [cve.id: .found("1 new: CVE-2026-3")])
        XCTAssertEqual(woken.map(\.0), [lead])
        XCTAssertTrue(woken.first?.1.contains(#"entries="CVE-2026-3""#) == true, "\(woken)")

        board.refused = true
        checked = await watcher.check([(cve, [lead])], keeping: [], at: now.addingTimeInterval(7_200)) { woken.append(($0, $1)) }
        guard case .failed? = checked[cve.id] else { return XCTFail("\(checked)") }
        XCTAssertEqual(woken.count, 1, "A failed check wakes no one")
    }

    @MainActor func testAWatchedToolsSkillSaysWhatItsWakeMeans() throws {
        let watcher = AlertWatcher(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), alerts: { _, _ in [] })
        watcher.adapters = PionAdapters.all
        let defender = try Defender.preset.makeConnection(name: "Defender", values: ["tenant": "contoso.onmicrosoft.com"])
        let skill = try XCTUnwrap(watcher.skillText(for: defender))
        XCTAssertTrue(skill.hasPrefix("## Alerts"), skill)
        XCTAssertTrue(skill.contains("<tool-alerts"), skill)
        XCTAssertTrue(skill.contains("`alerts`"), "It names the tool that reads them: \(skill)")
        let lookup = try VirusTotal.preset.makeConnection(name: "VirusTotal", values: [:])
        XCTAssertNil(watcher.skillText(for: lookup), "A lookup is never watched")
    }
}

/// The board an MCP server's tool answers with, in turn.
private final class Board: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    private var _refused = false
    private var _reads = 0
    var ids: [String] { get { lock.withLock { _ids } } set { lock.withLock { _ids = newValue } } }
    var refused: Bool { get { lock.withLock { _refused } } set { lock.withLock { _refused = newValue } } }
    var reads: Int { lock.withLock { _reads } }
    func answer() throws -> Data {
        let (ids, refused) = lock.withLock { _reads += 1; return (_ids, _refused) }
        if refused { throw ToolConnectionServiceError.network(503) }
        return CVENowTests.ranking(ids)
    }
}
