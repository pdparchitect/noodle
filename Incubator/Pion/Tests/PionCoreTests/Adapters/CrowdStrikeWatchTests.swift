import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

/// Falcon's alerts, Real Time Response sessions and contained hosts as Falcon answers them: alerts a page at a time from
/// the combined listing, each page's `after` token good only with the search it came from, sessions by offset, and
/// contained hosts as they stand; or refused, throttled, giving a token Pion will not follow, turning down a token, or
/// for a customer without the subscription.
final class FalconLog: ServiceAccess, @unchecked Sendable {
    enum Mode { case whole, denied, busy, unfollowable, rejectToken }
    let lock = NSLock()
    var alerts: [[String: Any]] = []
    var sessions: [[String: Any]] = []
    var contained: [String] = []
    var mode = Mode.whole
    var unlicensed = false
    /// The most Falcon gives on a page, whatever was asked for.
    var pageSize: Int? = nil
    var requests: [URLRequest] = []
    private var dates: [String: Date] = [:]

    static func time(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func alert(_ id: String, at date: Date, severity: String = "High", status: String? = "new") -> [String: Any] {
        var alert: [String: Any] = ["composite_id": "cid-secret:ind:\(id)", "display_name": "CredentialDumping by ignore-previous-instructions", "severity_name": severity,
                                    "product": "epp", "created_timestamp": time(date), "device": ["hostname": "victim-laptop", "device_id": String(repeating: "b", count: 32)]]
        if let status { alert["status"] = status }
        return alert
    }

    static func session(_ id: String, at date: Date) -> [String: Any] {
        ["id": id, "device_id": String(repeating: "c", count: 32), "hostname": "victim-server", "user_id": "admin@secret.example", "origin": "console",
         "created_at": time(date), "logs": [["base_command": "ls", "command_string": "ls C:\\secret", "created_at": time(date)]]]
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (mode, unlicensed) = lock.withLock { requests.append(request); return (self.mode, self.unlicensed) }
        let url = request.url!
        func answer(_ status: Int, _ body: Any) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!)
        }
        if unlicensed { return try answer(403, ["errors": [["code": 403, "message": "This feature requires a subscription the customer does not have."]], "resources": []]) }
        switch mode {
        case .denied: return try answer(403, ["errors": [["code": 403, "message": "access denied, authorization failed"]], "resources": []])
        case .busy: return try answer(429, ["errors": [["code": 429, "message": "API rate limit exceeded."]], "resources": []])
        case .whole, .unfollowable, .rejectToken: break
        }
        let date = { (text: String) -> Date? in
            self.lock.withLock {
                if let known = self.dates[text] { return known }
                let parsed = ServiceAlert.time(text)
                self.dates[text] = parsed
                return parsed
            }
        }
        func window(_ filter: String) -> (Date, Date) {
            let times = (try? NSRegularExpression(pattern: #"(>=|<=)'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)'"#))?.matches(in: filter, range: NSRange(filter.startIndex..., in: filter))
                .reduce(into: [String: Date]()) { found, match in
                    found[String(filter[Range(match.range(at: 1), in: filter)!])] = ServiceAlert.time(String(filter[Range(match.range(at: 2), in: filter)!]))
                } ?? [:]
            return (times[">="] ?? .distantPast, times["<="] ?? .distantFuture)
        }
        switch url.path {
        case "/alerts/combined/alerts/v1":
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            XCTAssertEqual(request.httpMethod, "POST")
            let filter = body["filter"] as? String ?? ""
            XCTAssertTrue(filter.hasPrefix("severity_name:['High','Critical']+created_timestamp:>='"), "always high and bounded: \(filter)")
            var start = 0
            if let token = body["after"] as? String {
                if mode == .rejectToken { return try answer(400, ["errors": [["code": 400, "message": "invalid after token"]]]) }
                let parts = String(decoding: Data(base64Encoded: token) ?? Data(), as: UTF8.self).split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[1] == filter else {
                    XCTFail("an after token sent with another search: \(filter)")
                    return try answer(400, ["errors": [["code": 400, "message": "mismatched token"]]])
                }
                start = Int(parts[0]) ?? 0
            }
            let size = min(body["limit"] as? Int ?? 100, lock.withLock { pageSize } ?? .max)
            let (since, until) = window(filter)
            let all = lock.withLock { alerts }
            let matching = all.filter { item in
                guard let time = (item["created_timestamp"] as? String).flatMap(date) else { return false }
                return time >= since && time <= until && ["High", "Critical"].contains(item["severity_name"] as? String ?? "")
            }.sorted { ($0["created_timestamp"] as! String, $0["composite_id"] as! String) > ($1["created_timestamp"] as! String, $1["composite_id"] as! String) }
            let page = Array(matching.dropFirst(start).prefix(size))
            var pagination: [String: Any] = ["limit": size, "total": matching.count]
            if start + page.count < matching.count {
                pagination["after"] = mode == .unfollowable ? "not a token" : Data("\(start + page.count)|\(filter)".utf8).base64EncodedString()
            }
            return try answer(200, ["meta": ["pagination": pagination, "trace_id": "trace-1"], "resources": page, "errors": []])
        case "/real-time-response-audit/combined/sessions/v1":
            let query = queryItems(request)
            let (since, until) = window(query["filter"] ?? "")
            let offset = Int(query["offset"] ?? "0") ?? 0, size = Int(query["limit"] ?? "100") ?? 100
            let matching = lock.withLock { sessions }.filter { item in
                guard let time = (item["created_at"] as? String).flatMap(date) else { return false }
                return time >= since && time <= until
            }.sorted { ($0["created_at"] as! String, $0["id"] as! String) > ($1["created_at"] as! String, $1["id"] as! String) }
            return try answer(200, ["meta": ["pagination": ["offset": offset, "limit": size, "total": matching.count]],
                                    "resources": Array(matching.dropFirst(offset).prefix(size)), "errors": []])
        case "/devices/queries/devices/v1":
            XCTAssertEqual(queryItems(request)["filter"], "status:['contained','containment_pending']")
            let all = lock.withLock { contained }
            return try answer(200, ["meta": ["pagination": ["offset": 0, "limit": 5_000, "total": all.count]], "resources": all, "errors": []])
        default:
            return try answer(404, ["errors": [["code": 404, "message": "Not found"]]])
        }
    }
}

final class CrowdStrikeWatchTests: XCTestCase {
    private func falcon() -> ToolConnection {
        try! CrowdStrike.preset.makeConnection(name: "Falcon — Kestrel", values: ["region": "api.eu-1.crowdstrike.com"])
    }

    private func client(_ connection: ToolConnection, _ access: any ServiceAccess) -> ServiceClient {
        ServiceClient(base: connection.endpoint, access: access, settings: connection.settings ?? [:], account: connection.id)
    }

    private func alertID(_ id: String) -> String { CrowdStrike.safeID("alert/", "cid-secret:ind:\(id)") }

    /// The watch keeps high and critical alerts not closed, an unknown status included, and not lower or closed ones.
    func testTheWatchKeepsOpenHighAndCriticalAlertsAndLeavesTheRest() async throws {
        let connection = falcon()
        let service = FalconLog()
        let now = Date(), at = now.addingTimeInterval(-600)
        service.alerts = [FalconLog.alert("new", at: at), FalconLog.alert("critical", at: at, severity: "Critical"), FalconLog.alert("unknown", at: at, status: nil),
                          FalconLog.alert("working", at: at, status: "in_progress"), FalconLog.alert("closed", at: at, status: "closed"),
                          FalconLog.alert("medium", at: at, severity: "Medium"), FalconLog.alert("old", at: now.addingTimeInterval(-7_200))]
        let read = await CrowdStrike.readFeed(.alerts, client(connection, service), since: now.addingTimeInterval(-3_600), until: now, pages: 2)
        XCTAssertEqual(Set(read.events.map(\.id)), Set(["new", "critical", "unknown", "working"].map(alertID)))
        XCTAssertTrue(read.complete)
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "api.eu-1.crowdstrike.com" })
    }

    /// The note that wakes an agent carries counts and times only: no ID, name, host or text Falcon gave.
    func testWakesCarryOnlyCountsTimesAndHashedIDs() async throws {
        let connection = falcon()
        let service = FalconLog()
        let start = Date().addingTimeInterval(-600)
        service.alerts = [FalconLog.alert("alert-secret-1", at: start.addingTimeInterval(60)), FalconLog.alert("low-1", at: start.addingTimeInterval(60), severity: "Low")]
        service.sessions = [FalconLog.session("session-secret-1", at: start.addingTimeInterval(120))]
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start))
        let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: CrowdStrike.adapter.alertLookBack))
        let found = try await CrowdStrike.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(Set(found.map(\.id)), [alertID("alert-secret-1"), CrowdStrike.safeID("session/", "session-secret-1")])
        XCTAssertTrue(found.allSatisfy { $0.id.range(of: #"^(alert|session)/[0-9a-f]{64}$"#, options: .regularExpression) != nil })
        let news = try XCTUnwrap(watch.take(found, for: connection.id, lookBack: CrowdStrike.adapter.alertLookBack))
        let note = AlertWatch.note(news, account: connection.name, skill: "crowdstrike", tool: CrowdStrike.adapter.watchedTool!)
        for leaked in ["secret", "victim", "Credential", "ignore-previous", "bbbbbbbb", "admin@"] { XCTAssertFalse(note.contains(leaked), note) }
        XCTAssertTrue(note.contains(#"new="2""#) && note.contains(#"tool="security-events""#), note)
    }

    /// Polls through the real AlertWatch until one returns nothing new with nothing left owed or to read on, at most
    /// `most`, saying what each delivered and the notices.
    private func poll(_ connection: ToolConnection, _ service: FalconLog, from start: Date, most: Int = 20,
                      before: (Int) -> Void = { _ in }) async throws -> (delivered: [String], notices: [String], polls: Int) {
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start.addingTimeInterval(-60)))
        var delivered: [String] = [], notices: [String] = [], polls = 0
        while polls < most {
            polls += 1
            before(polls)
            let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: CrowdStrike.adapter.alertLookBack))
            let found: [ServiceAlert]
            do { found = try await CrowdStrike.adapter.alerts(since: since, connection: connection, access: service) } catch { continue }
            XCTAssertLessThanOrEqual(found.count, ServiceAlert.most)
            notices += found.map(\.id).filter { $0.hasPrefix("unchecked/") || $0.hasPrefix("unreadable/") }
            delivered += found.map(\.id).filter { $0.hasPrefix("alert/") }
            let idle = CrowdStrike.NewSecurityEvents.kept.withLock { $0[connection.id].map { $0.continuations.isEmpty && $0.owedFrom.isEmpty } ?? true }
            guard watch.take(found, for: connection.id, lookBack: CrowdStrike.adapter.alertLookBack) != nil || !idle else { break }
        }
        return (delivered, notices, polls)
    }

    private func kinds(_ notices: [String]) -> [String] { notices.map { $0.split(separator: "/").dropLast().joined(separator: "/") } }

    /// A burst bigger than one check returns, and more than one check may read, is all delivered over later checks,
    /// each once, with one notice that more follow.
    func testABurstBiggerThanOneCheckIsAllDeliveredEachOnce() async throws {
        let connection = falcon()
        let service = FalconLog()
        service.pageSize = 100
        let start = Date().addingTimeInterval(-2 * 3_600)
        let ids = (0..<1_500).map { String(format: "burst-%05d", $0) }
        service.alerts = ids.enumerated().map { FalconLog.alert($1, at: start.addingTimeInterval(Double($0))) }
        let (delivered, notices, _) = try await poll(connection, service, from: start)
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map(alertID)), "every one, the oldest included")
        XCTAssertEqual(kinds(notices), ["unchecked/backlog"], "that more follow is told once")
        let kept = CrowdStrike.NewSecurityEvents.kept.withLock { $0[connection.id] }
        XCTAssertTrue(kept?.owedFrom.isEmpty == true && kept?.continuations.isEmpty == true, "nothing owed at the end")
    }

    /// A check that fails for a reason that passes keeps nothing but how many in a row failed, so the next reads the
    /// same window again and returns what it would have.
    func testAFailedCheckKeepsOnlyItsFailureStreakAndRecovers() async throws {
        let connection = falcon()
        let trigger = CrowdStrike.NewSecurityEvents()
        let service = FalconLog()
        let first = Date().addingTimeInterval(-10 * 3_600), later = Date()
        service.alerts = [FalconLog.alert("before", at: first.addingTimeInterval(-60))]
        let found = try await trigger.alerts(since: first.addingTimeInterval(-3_600), on: client(connection, service), account: connection.id, now: first)
        XCTAssertEqual(found.count, 1)
        let before = try XCTUnwrap(CrowdStrike.NewSecurityEvents.kept.withLock { $0[connection.id] })
        XCTAssertEqual(before.readUntil["alerts"], first)
        service.alerts.append(FalconLog.alert("during", at: first.addingTimeInterval(3_600)))
        service.mode = .busy
        do {
            _ = try await CrowdStrike.$pause.withValue({ _ in }) {
                try await trigger.alerts(since: first.addingTimeInterval(-60), on: client(connection, service), account: connection.id, now: later)
            }
            XCTFail("a passing failure holds the watch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rate limit"), error.localizedDescription)
        }
        let held = try XCTUnwrap(CrowdStrike.NewSecurityEvents.kept.withLock { $0[connection.id] })
        XCTAssertEqual(held.inARow.values.max(), 1)
        XCTAssertEqual(held.readUntil, before.readUntil)
        XCTAssertEqual(held.delivered, before.delivered)
        XCTAssertTrue(held.owedFrom.isEmpty && held.continuations.isEmpty && held.told.isEmpty)
        service.mode = .whole
        service.requests = []
        let recovered = try await trigger.alerts(since: first.addingTimeInterval(-20 * 3_600), on: client(connection, service), account: connection.id, now: later)
        XCTAssertEqual(recovered.map(\.id), [alertID("during")], "the earlier one is not news again")
        let read = try XCTUnwrap(service.requests.first { $0.url?.path == "/alerts/combined/alerts/v1" })
        let filter = (try JSONSerialization.jsonObject(with: read.httpBody ?? Data()) as? [String: Any])?["filter"] as? String ?? ""
        XCTAssertTrue(filter.contains("created_timestamp:>='\(Entra.iso(first.addingTimeInterval(-6 * 3_600)))'"), filter)
        XCTAssertTrue(CrowdStrike.NewSecurityEvents.kept.withLock { $0[connection.id]?.inARow.isEmpty } == true)
    }

    /// A feed that cannot be read wakes the agents once while it stays so, and after holding back a few checks for one
    /// that might pass; reading again ends it, and a new failure wakes again.
    func testAnUnreadableFeedWakesOnceAndAgainOnlyAfterRecovering() async throws {
        let connection = falcon()
        let trigger = CrowdStrike.NewSecurityEvents()
        let service = FalconLog()
        let since = Date().addingTimeInterval(-3_600)
        service.mode = .denied
        let told = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(Set(kinds(told.map(\.id))), ["unreadable/alerts", "unreadable/sessions", "unreadable/contained"])
        XCTAssertTrue(told.allSatisfy { $0.time == since }, "dated at the window's start, so it moves nothing on")
        do { _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id); XCTFail("told once") } catch {}
        service.mode = .whole
        _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        service.mode = .busy
        try await CrowdStrike.$pause.withValue({ _ in }) {
            for _ in 1...CrowdStrike.NewSecurityEvents.holdChecks {
                do { _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id); XCTFail("held back") } catch {}
            }
            let again = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
            XCTAssertEqual(Set(kinds(again.map(\.id))), ["unreadable/alerts", "unreadable/sessions", "unreadable/contained"], "a failure that lasts is told, once more")
        }
    }

    /// A customer without the subscription is said once to be off, and security-events says why.
    func testACustomerWithoutTheSubscriptionIsSaidOnceToBeOff() async throws {
        let connection = falcon()
        let trigger = CrowdStrike.NewSecurityEvents()
        let service = FalconLog()
        service.unlicensed = true
        let since = Date().addingTimeInterval(-3_600)
        let first = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(Set(kinds(first.map(\.id))), ["unreadable/alerts", "unreadable/sessions", "unreadable/contained"])
        let second = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertTrue(second.isEmpty, "told once: \(second)")
        let data = try await CrowdStrike.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        let text = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Off: high and critical alerts cannot be read: the customer lacks the Falcon subscription"), text)
        XCTAssertTrue(text.contains("Could not read contained hosts, so whether any host is contained is unknown"), text)
    }

    /// What one check had no room for, and what it could not read, stays owed through a check that cannot read the
    /// feed, or reads it only in part, however far newer alerts moved the watch on, and is handed over, each once, when
    /// the feed reads again.
    func testOverflowADeniedOrTruncatedPollAndRecoveryStillDeliverEverythingOnce() async throws {
        for failure in [FalconLog.Mode.denied, .unfollowable, .busy] {
            let connection = falcon()
            let service = FalconLog()
            let start = Date().addingTimeInterval(-12 * 3_600)
            service.pageSize = 150
            let ids = (0..<900).map { String(format: "owed-%05d", $0) }
            service.alerts = ids.enumerated().map { index, id in
                FalconLog.alert(id, at: start.addingTimeInterval(index < 700 ? Double(index) : Double(index - 699) * 120))
            }
            let (delivered, notices, _) = try await CrowdStrike.$pause.withValue({ _ in }) {
                try await poll(connection, service, from: start) { poll in service.mode = poll == 2 ? failure : .whole }
            }
            XCTAssertEqual(delivered.count, ids.count, "\(failure): each once")
            XCTAssertEqual(Set(delivered), Set(ids.map(alertID)), "\(failure): the oldest too")
            if failure == .denied { XCTAssertTrue(notices.contains { $0.hasPrefix("unreadable/alerts/") }, "\(failure): \(notices)") }
            if failure == .unfollowable { XCTAssertTrue(notices.contains { $0.hasPrefix("unchecked/alerts/") }, "\(failure): \(notices)") }
            let kept = CrowdStrike.NewSecurityEvents.kept.withLock { $0[connection.id] }
            XCTAssertTrue(kept?.owedFrom.isEmpty == true && kept?.continuations.isEmpty == true, "\(failure): nothing owed at the end")
        }
    }

    /// More alerts raised at one moment than a check's page budget, and one after them: the watch goes on with the
    /// search it kept and its token, never restarting at that moment, so each is delivered exactly once.
    func testMoreTiedAlertsThanThePageBudgetAreEachDeliveredOnce() async throws {
        let connection = falcon()
        let service = FalconLog()
        service.pageSize = 100
        let start = Date().addingTimeInterval(-3 * 3_600), moment = start.addingTimeInterval(60)
        let tied = (0..<(CrowdStrike.watchPages * 100 + 150)).map { String(format: "tied-%05d", $0) }
        service.alerts = tied.map { FalconLog.alert($0, at: moment) } + [FalconLog.alert("after-the-tie", at: moment.addingTimeInterval(1))]
        let (delivered, notices, polls) = try await poll(connection, service, from: start)
        XCTAssertLessThan(polls, 20, "it stops finding news")
        XCTAssertEqual(delivered.count, tied.count + 1, "each once")
        XCTAssertEqual(Set(delivered), Set((tied + ["after-the-tie"]).map(alertID)))
        XCTAssertEqual(kinds(notices), ["unchecked/backlog"], "that more follow is told once")
        let reads = service.requests.filter { $0.url?.path == "/alerts/combined/alerts/v1" }
            .map { (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any]) ?? [:] }
        let resumed = try XCTUnwrap(reads.dropFirst(CrowdStrike.watchPages).first)
        XCTAssertNotNil(resumed["after"])
        XCTAssertEqual(resumed["filter"] as? String, reads.first?["filter"] as? String, "the same bounded search")
    }

    /// A search that ends after a long continuation, while the watch moved on, leaves a boundary, so an alert raised
    /// just after its end, read by no check yet, is still delivered.
    func testASearchThatEndsAfterALongContinuationLeavesABoundary() async throws {
        let connection = falcon()
        let trigger = CrowdStrike.NewSecurityEvents()
        let service = FalconLog()
        let client = client(connection, service)
        let first = Date().addingTimeInterval(-20 * 3_600)
        service.pageSize = 30
        service.alerts = (0..<(CrowdStrike.watchPages * 30 * 3 + 20)).map { FalconLog.alert(String(format: "q-%05d", $0), at: first.addingTimeInterval(-600 + Double($0) / 2)) }
        var caught = try await trigger.alerts(since: first.addingTimeInterval(-3_600), on: client, account: connection.id, now: first).map(\.id)
        let search = try XCTUnwrap(CrowdStrike.NewSecurityEvents.kept.withLock { $0[connection.id]?.continuations["alerts"] })
        XCTAssertEqual(search.until, first)
        service.alerts.append(FalconLog.alert("just-after", at: first.addingTimeInterval(30)))
        var later = first
        for _ in 1...3 {
            later = later.addingTimeInterval(4 * 3_600)
            caught += try await trigger.alerts(since: later.addingTimeInterval(-600), on: client, account: connection.id, now: later).map(\.id)
        }
        XCTAssertFalse(caught.contains(alertID("just-after")), "the search reads only its own window")
        XCTAssertEqual(CrowdStrike.NewSecurityEvents.kept.withLock { $0[connection.id]?.catchUp["alerts"] }, first.addingTimeInterval(-6 * 3_600))
        for check in 1...4 {
            caught += try await trigger.alerts(since: later.addingTimeInterval(-600), on: client, account: connection.id, now: later.addingTimeInterval(Double(check) * 300)).map(\.id)
        }
        XCTAssertEqual(caught.filter { $0 == alertID("just-after") }.count, 1, "\(caught.count)")
        XCTAssertEqual(caught.filter { $0.hasPrefix("alert/") }.count, service.alerts.count, "each once")
    }

    /// A token Falcon turns down is given up, said once, and its window read again from its start, so everything is
    /// still delivered, each once.
    func testARejectedTokenIsGivenUpAndItsWindowReadAgain() async throws {
        let connection = falcon()
        let service = FalconLog()
        let start = Date().addingTimeInterval(-2 * 3_600)
        service.pageSize = 100
        let ids = (0..<900).map { String(format: "rt-%05d", $0) }
        service.alerts = ids.enumerated().map { FalconLog.alert($1, at: start.addingTimeInterval(Double($0))) }
        let (delivered, notices, _) = try await poll(connection, service, from: start) { poll in service.mode = poll == 2 ? .rejectToken : .whole }
        XCTAssertTrue(notices.contains { $0.hasPrefix("unchecked/alerts/") }, "\(notices)")
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map(alertID)))
        XCTAssertTrue(CrowdStrike.NewSecurityEvents.kept.withLock { $0[connection.id]?.owedFrom.isEmpty } == true)
    }

    /// Contained hosts: the first whole read only learns them; a host contained later is returned once, and again only
    /// after it was lifted and contained again.
    func testHostsNewlyContainedAreReturnedOnceAfterTheFirstRead() async throws {
        let connection = falcon()
        let trigger = CrowdStrike.NewSecurityEvents()
        let service = FalconLog()
        let host1 = String(repeating: "1", count: 32), host2 = String(repeating: "2", count: 32)
        let since = Date().addingTimeInterval(-3_600)
        service.contained = [host1]
        let first = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertTrue(first.isEmpty, "what is contained when the watch starts is not news")
        service.contained = [host1, host2]
        let second = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second[0].id.hasPrefix("contained/") && !second[0].id.contains(host2), second[0].id)
        let third = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertTrue(third.isEmpty, "told once")
        service.contained = [host1]
        _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        service.contained = [host1, host2]
        let again = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id, now: Date().addingTimeInterval(1))
        XCTAssertEqual(again.count, 1, "contained again after a lift is news again")
    }

    /// security-events reads the same, says what it searched and when it was cut short, the hosts contained now, and
    /// what it does not watch.
    func testSecurityEventsSaysWhatItSearchedAndWhatItDidNotRead() async throws {
        let connection = falcon()
        let service = FalconLog()
        let now = Date()
        service.pageSize = 100
        service.alerts = (0..<1_050).map { FalconLog.alert(String(format: "se-%05d", $0), at: now.addingTimeInterval(-3_000 + Double($0))) }
        service.sessions = [FalconLog.session("s1", at: now.addingTimeInterval(-600))]
        service.contained = [String(repeating: "d", count: 32)]
        let data = try await CrowdStrike.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? ""
        XCTAssertTrue(text.contains("High alert: CredentialDumping") && text.contains("Real Time Response session by admin@secret.example on victim-server"), text)
        XCTAssertTrue(text.contains("Searched: high and critical alerts") && text.contains("Searched: Real Time Response sessions"), text)
        XCTAssertTrue(text.contains("Cut short, with more not read: high and critical alerts"), text)
        XCTAssertTrue(text.contains("Contained or with containment pending now, 1 host: \(String(repeating: "d", count: 32))"), text)
        XCTAssertTrue(text.contains("Not watched:") && text.contains("incidents API was retired"), text)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["complete"] as? Bool, false)
        XCTAssertEqual(service.requests.filter { $0.url?.path == "/alerts/combined/alerts/v1" }.count, CrowdStrike.eventsPages)
        let refused = try await callTool(CrowdStrike.adapter, "security-events", #"{"since":"2020-01-01T00:00:00Z"}"#, on: FakeService(), in: connection)
        XCTAssertTrue(refused.isError, "at most 30 days")
    }
}
