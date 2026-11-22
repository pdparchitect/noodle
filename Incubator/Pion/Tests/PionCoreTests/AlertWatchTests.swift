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

    /// Google lists a few audit events later than an hour, so Workspace's checks read six hours back.
    @MainActor func testWorkspaceChecksReadSixHoursBack() async throws {
        let workspace = try GoogleWorkspace.preset.makeConnection(name: "Workspace", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let asked = SinceLog()
        let watcher = AlertWatcher(file: file, alerts: { _, since in
            asked.add(since)
            return [ServiceAlert(id: "x", time: now.addingTimeInterval(7_200))]
        })
        watcher.adapters = PionAdapters.all
        for minutes in [0.0, 150, 155] { _ = await watcher.check([(workspace, [UUID()])], keeping: [], at: now.addingTimeInterval(minutes * 60)) { _, _ in } }
        XCTAssertEqual(asked.values.last, now, "read from six hours before the newest event, never before watching started")
    }

    /// Google Cloud's watch, where Security Command Center is not activated, wakes the agents once to say so, pointing
    /// them at security-events, and goes on watching the audit logs rather than failing every check; the telling moves
    /// the watch past nothing.
    @MainActor func testGoogleCloudTellsOnceThatSecurityCommandCenterCannotBeReadAndKeepsWatchingTheAuditLogs() async throws {
        let cloud = try GoogleCloud.preset.makeConnection(name: "Google Cloud", values: ["level": "projects", "id": "kestrel-prod", "clientID": "1234-abc.apps.googleusercontent.com"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T00:00:00Z"))
        let service = FakeService()
        service.answers["/v2/projects/kestrel-prod/sources/-/findings"] = (400, #"{"error":{"code":400,"message":"Security Command Center is not activated for this resource.","status":"FAILED_PRECONDITION"}}"#)
        service.answers["/v2/entries:list"] = (200, #"{"entries":[{"insertId":"key","timestamp":"2026-11-21T08:00:00Z","logName":"projects/kestrel-prod/logs/cloudaudit.googleapis.com%2Factivity","protoPayload":{"serviceName":"iam.googleapis.com","methodName":"google.iam.admin.v1.CreateServiceAccountKey","resourceName":"projects/-/serviceAccounts/1","authenticationInfo":{"principalEmail":"mallory@kestrel.example"},"status":{}}}]}"#)
        let asked = SinceLog()
        let watcher = AlertWatcher(file: file, alerts: { connection, since in
            asked.add(since)
            return try await GoogleCloud.adapter.alerts(since: since, connection: connection, access: service)
        })
        watcher.adapters = PionAdapters.all
        var woken: [String] = []
        var checked = await watcher.check([(cloud, [UUID()])], keeping: [], at: start) { woken.append($1) }
        XCTAssertEqual(checked, [cloud.id: .started])
        checked = await watcher.check([(cloud, [UUID()])], keeping: [], at: start.addingTimeInterval(20 * 3_600)) { woken.append($1) }
        XCTAssertEqual(checked, [cloud.id: .found("2 new alerts")], "the key made and Security Command Center that cannot be read")
        XCTAssertTrue(woken.first?.contains(#"tool="security-events""#) == true && woken.first?.contains(#"since="2026-11-21T00:00:00Z""#) == true, "\(woken)")
        XCTAssertTrue(watcher.skillText(for: cloud)?.contains("Read them with `security-events`") == true)
        checked = await watcher.check([(cloud, [UUID()])], keeping: [], at: start.addingTimeInterval(20 * 3_600 + 300)) { woken.append($1) }
        XCTAssertEqual(checked, [cloud.id: .nothingNew], "told again, or the check failed")
        XCTAssertEqual(asked.values.last, start.addingTimeInterval(2 * 3_600), "read from six hours before the newest event, not from now")
    }

    /// A Workspace report the watch is refused for good wakes the agents once, so they learn the watch cannot read it,
    /// and the checks after it go on rather than failing every time.
    @MainActor func testWorkspaceTellsOnceOfAReportItCannotRead() async throws {
        let workspace = try GoogleWorkspace.preset.makeConnection(name: "Workspace", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let service = FakeService()
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        service.answers[reports + "rules"] = (403, #"{"error":{"code":403,"message":"Not Authorized to access this resource/api"}}"#)
        let watcher = AlertWatcher(file: file, alerts: { connection, since in
            try await GoogleWorkspace.adapter.alerts(since: since, connection: connection, access: service)
        })
        watcher.adapters = PionAdapters.all
        let lead = UUID()
        var woken: [String] = []
        var checked = await watcher.check([(workspace, [lead])], keeping: [], at: now) { woken.append($1) }
        XCTAssertEqual(checked, [workspace.id: .started])
        checked = await watcher.check([(workspace, [lead])], keeping: [], at: now.addingTimeInterval(300)) { woken.append($1) }
        XCTAssertEqual(checked, [workspace.id: .found("1 new alert")])
        XCTAssertTrue(woken.first?.contains(#"tool="security-events""#) == true, "\(woken)")
        checked = await watcher.check([(workspace, [lead])], keeping: [], at: now.addingTimeInterval(600)) { woken.append($1) }
        XCTAssertEqual(checked, [workspace.id: .nothingNew], "told again, or the check failed")
        XCTAssertEqual(woken.count, 1)
    }

    /// Telling of a report it cannot read never moves the watch on: after a night away, the next check still reads
    /// from six hours before the newest event found, not from six hours before now.
    @MainActor func testWorkspaceTellingOfAnUnreadableReportMovesTheWatchPastNothing() async throws {
        let workspace = try GoogleWorkspace.preset.makeConnection(name: "Workspace", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
        let service = FakeService()
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        service.answers[reports + "login"] = (200, #"{"items":[{"id":{"time":"2026-11-14T08:00:00.000Z","uniqueQualifier":"1"},"events":[{"name":"suspicious_login"}]}]}"#)
        service.answers[reports + "rules"] = (403, #"{"error":{"code":403,"message":"Not Authorized to access this resource/api"}}"#)
        let asked = SinceLog()
        let watcher = AlertWatcher(file: file, alerts: { connection, since in
            asked.add(since)
            return try await GoogleWorkspace.adapter.alerts(since: since, connection: connection, access: service)
        })
        watcher.adapters = PionAdapters.all
        var woken: [String] = []
        _ = await watcher.check([(workspace, [UUID()])], keeping: [], at: start) { woken.append($1) }
        let overnight = await watcher.check([(workspace, [UUID()])], keeping: [], at: start.addingTimeInterval(20 * 3_600)) { woken.append($1) }
        XCTAssertEqual(overnight, [workspace.id: .found("2 new alerts")], "the sign-in and the report that cannot be read")
        XCTAssertTrue(woken.first?.contains(#"since="2026-11-14T00:00:00Z""#) == true, "\(woken)")
        _ = await watcher.check([(workspace, [UUID()])], keeping: [], at: start.addingTimeInterval(20 * 3_600 + 300)) { woken.append($1) }
        XCTAssertEqual(asked.values.last, start.addingTimeInterval(2 * 3_600), "read from six hours before the newest event, not from now")
    }

    /// A report read whole, such as Vault's, that the watch is refused is told once, by its report, and a risky app grant
    /// found beside it still wakes the agents; one that fails for now holds the check back, naming the report.
    @MainActor func testWorkspaceTellsOnceOfAReportReadWholeItCannotRead() async throws {
        let workspace = try GoogleWorkspace.preset.makeConnection(name: "Workspace", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let service = FakeService()
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        service.answers[reports + "vault"] = (403, #"{"error":{"code":403,"message":"Not Authorized to access this resource/api"}}"#)
        let watcher = AlertWatcher(file: file, alerts: { connection, since in
            try await GoogleWorkspace.adapter.alerts(since: since, connection: connection, access: service)
        })
        watcher.adapters = PionAdapters.all
        var woken: [String] = []
        _ = await watcher.check([(workspace, [UUID()])], keeping: [], at: now) { woken.append($1) }
        let time = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        service.answers[reports + "token"] = (200, #"{"items":[{"id":{"time":"\#(time)","uniqueQualifier":"1"},"actor":{"email":"nick@kestrel.example"},"events":[{"name":"authorize","parameters":[{"name":"app_name","value":"Mail Helper"},{"name":"scope","multiValue":["https://mail.google.com/"]}]}]}]}"#)
        var checked = await watcher.check([(workspace, [UUID()])], keeping: [], at: now.addingTimeInterval(300)) { woken.append($1) }
        XCTAssertEqual(checked, [workspace.id: .found("2 new alerts")], "the grant and the report that cannot be read")
        checked = await watcher.check([(workspace, [UUID()])], keeping: [], at: now.addingTimeInterval(600)) { woken.append($1) }
        XCTAssertEqual(checked, [workspace.id: .nothingNew], "told again, or the check failed")
        let other = try GoogleWorkspace.preset.makeConnection(name: "Workspace — other", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let alerts = try await GoogleWorkspace.adapter.alerts(since: now, connection: other, access: service)
        XCTAssertEqual(alerts.filter { $0.id.hasPrefix("unreadable/") }.map { $0.id.split(separator: "/")[1] }, ["vault"], "\(alerts)")
        service.answers[reports + "admin"] = (503, #"{"error":{"code":503,"message":"Backend Error"}}"#)
        do {
            _ = try await GoogleWorkspace.adapter.alerts(since: now, connection: workspace, access: service)
            XCTFail("a check that could not read the admin report for now moved on")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not read admin for now"), error.localizedDescription)
        }
    }

    /// A report that stops answering, answers again and stops again is told each time it stops, once.
    @MainActor func testWorkspaceTellsEachOutageOfAReportOnce() async throws {
        let workspace = try GoogleWorkspace.preset.makeConnection(name: "Workspace", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let service = FakeService()
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        let denied = (403, #"{"error":{"code":403,"message":"Not Authorized to access this resource/api"}}"#)
        let watcher = AlertWatcher(file: file, alerts: { connection, since in
            try await GoogleWorkspace.adapter.alerts(since: since, connection: connection, access: service)
        })
        watcher.adapters = PionAdapters.all
        var results: [AlertWatcher.Checked?] = []
        for (minute, rules) in [(0, denied), (5, denied), (10, denied), (15, (200, #"{"items":[]}"#)), (20, denied), (25, denied)] {
            service.answers[reports + "rules"] = rules
            let checked = await watcher.check([(workspace, [UUID()])], keeping: [], at: now.addingTimeInterval(Double(minute) * 60)) { _, _ in }
            results.append(checked[workspace.id])
        }
        XCTAssertEqual(results, [.started, .found("1 new alert"), .nothingNew, .nothingNew, .found("1 new alert"), .nothingNew])
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

private final class SinceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [Date] = []
    func add(_ date: Date) { lock.withLock { kept.append(date) } }
    var values: [Date] { lock.withLock { kept } }
}
