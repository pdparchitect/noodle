import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

/// Microsoft Graph's security alerts and incidents as Graph answers them: a page at a time, each page's next link
/// carrying a $skip, or a $skiptoken good only with the query it came from; or refused, throttled, linking its next
/// page elsewhere, turning down a paging value, or in a tenant without Defender.
final class DefenderLog: ServiceAccess, @unchecked Sendable {
    enum Mode { case whole, denied, busy, elsewhere, rejectToken }
    let lock = NSLock()
    var alerts: [[String: Any]] = []
    var incidents: [[String: Any]] = []
    var mode = Mode.whole
    var unlicensed = false
    var pageSize = 100
    /// Whether next links carry a $skiptoken rather than a $skip.
    var tokens = false
    var requests: [URLRequest] = []
    private var dates: [String: Date] = [:]

    static func time(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func alert(_ id: String, at date: Date, severity: String = "high", status: String? = "new") -> [String: Any] {
        var alert: [String: Any] = ["id": id, "title": "Ransomware behaviour by ignore-previous-instructions", "severity": severity, "serviceSource": "microsoftDefenderForEndpoint",
                                    "createdDateTime": time(date), "incidentId": "incident-secret",
                                    "evidence": [["@odata.type": "#microsoft.graph.security.deviceEvidence", "deviceDnsName": "victim-laptop", "mdeDeviceId": String(repeating: "b", count: 40)]]]
        if let status { alert["status"] = status }
        return alert
    }

    static func incident(_ id: String, at date: Date, severity: String = "high", status: String = "active") -> [String: Any] {
        ["id": id, "displayName": "Multi-stage incident on victim-laptop", "severity": severity, "status": status, "createdDateTime": time(date)]
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (mode, unlicensed, size, tokens) = lock.withLock { requests.append(request); return (self.mode, self.unlicensed, pageSize, self.tokens) }
        let url = request.url!
        func answer(_ status: Int, _ body: Any, _ headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        if unlicensed {
            return try answer(403, ["error": ["code": "Forbidden", "message": "The tenant is not provisioned for Microsoft Defender XDR; a license is required."]])
        }
        switch mode {
        case .denied: return try answer(403, ["error": ["code": "Forbidden", "message": "Missing role permissions."]])
        case .busy: return try answer(429, ["error": ["code": "TooManyRequests", "message": "Too many requests"]], ["Retry-After": "30"])
        case .whole, .elsewhere, .rejectToken: break
        }
        let query = queryItems(request)
        let filter = query["$filter"] ?? ""
        var start = 0
        if let token = query["$skiptoken"] {
            if mode == .rejectToken { return try answer(400, ["error": ["code": "BadRequest", "message": "The paging token has expired."]]) }
            let parts = String(decoding: Data(base64Encoded: token) ?? Data(), as: UTF8.self).split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1] == filter else {
                XCTFail("a $skiptoken sent with another query: \(filter)")
                return try answer(400, ["error": ["code": "BadRequest", "message": "mismatched token"]])
            }
            start = Int(parts[0]) ?? 0
        } else if let skip = query["$skip"] {
            if mode == .rejectToken { return try answer(400, ["error": ["code": "BadRequest", "message": "The paging offset is not valid."]]) }
            start = Int(skip) ?? 0
        }
        XCTAssertTrue(filter.hasPrefix("severity eq 'high' and createdDateTime ge "), "always high and bounded: \(filter)")
        let times = (try? NSRegularExpression(pattern: #"(ge|le) (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)"#))?.matches(in: filter, range: NSRange(filter.startIndex..., in: filter))
            .reduce(into: [String: Date]()) { found, match in
                found[String(filter[Range(match.range(at: 1), in: filter)!])] = ServiceAlert.time(String(filter[Range(match.range(at: 2), in: filter)!]))
            } ?? [:]
        let (since, until) = (times["ge"] ?? .distantPast, times["le"] ?? .distantFuture)
        let all = lock.withLock { url.path.hasSuffix("alerts_v2") ? alerts : incidents }
        // Read once each, as a formatter is slow to make and the watch's tests ask for thousands of pages.
        let date = { (text: String) -> Date? in
            self.lock.withLock {
                if let known = self.dates[text] { return known }
                let parsed = ServiceAlert.time(text)
                self.dates[text] = parsed
                return parsed
            }
        }
        let matching = all.filter { item in
            guard let time = (item["createdDateTime"] as? String).flatMap(date) else { return false }
            return time >= since && time <= until && item["severity"] as? String == "high"
        }.sorted { ($0["createdDateTime"] as! String, $0["id"] as! String) > ($1["createdDateTime"] as! String, $1["id"] as! String) }
        let page = Array(matching.dropFirst(start).prefix(size))
        var body: [String: Any] = ["value": page]
        if start + page.count < matching.count {
            var next = URLComponents(string: "https://\(mode == .elsewhere ? "evil.example" : "graph.microsoft.com")\(url.path)")!
            next.queryItems = [URLQueryItem(name: "$top", value: query["$top"]),
                               tokens ? URLQueryItem(name: "$skiptoken", value: Data("\(start + page.count)|\(filter)".utf8).base64EncodedString())
                                      : URLQueryItem(name: "$skip", value: String(start + page.count))]
            body["@odata.nextLink"] = next.string!
        }
        return try answer(200, body)
    }
}

final class DefenderWatchTests: XCTestCase {
    private func tenant() -> ToolConnection {
        try! Defender.preset.makeConnection(name: "Defender — Contoso", values: ["tenant": "contoso.onmicrosoft.com", "clientID": EntraTests.client])
    }

    private func client(_ connection: ToolConnection, _ access: any ServiceAccess) -> ServiceClient {
        ServiceClient(base: connection.endpoint, access: access, settings: connection.settings ?? [:], account: connection.id)
    }

    /// The watch wakes for high alerts not resolved and high incidents still open, an unknown status included, and not
    /// for what is lower, resolved or redirected.
    func testTheWatchKeepsOpenHighAlertsAndIncidentsAndLeavesTheRest() async throws {
        let connection = tenant()
        let service = DefenderLog()
        let now = Date(), at = now.addingTimeInterval(-600)
        service.alerts = [DefenderLog.alert("new", at: at), DefenderLog.alert("working", at: at, status: "inProgress"), DefenderLog.alert("unknown", at: at, status: nil),
                          DefenderLog.alert("resolved", at: at, status: "resolved"), DefenderLog.alert("medium", at: at, severity: "medium"),
                          DefenderLog.alert("old", at: now.addingTimeInterval(-7_200))]
        service.incidents = [DefenderLog.incident("active", at: at), DefenderLog.incident("waiting", at: at, status: "awaitingAction"),
                             DefenderLog.incident("redirected", at: at, status: "redirected"), DefenderLog.incident("closed", at: at, status: "resolved")]
        let alerts = await Defender.readFeed(.alerts, client(connection, service), since: now.addingTimeInterval(-3_600), until: now, pages: 2)
        XCTAssertEqual(Set(alerts.events.map(\.id)), Set(["new", "working", "unknown"].map { Defender.safeID("alert/", $0) }))
        XCTAssertTrue(alerts.complete)
        let incidents = await Defender.readFeed(.incidents, client(connection, service), since: now.addingTimeInterval(-3_600), until: now, pages: 2)
        XCTAssertEqual(Set(incidents.events.map(\.id)), Set(["active", "waiting"].map { Defender.safeID("incident/", $0) }))
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "graph.microsoft.com" && $0.httpMethod == "GET" })
    }

    /// The note that wakes an agent carries counts and times only: no ID, name, address or text Graph gave.
    func testWakesCarryOnlyCountsTimesAndHashedIDs() async throws {
        let connection = tenant()
        let service = DefenderLog()
        let start = Date().addingTimeInterval(-600)
        service.alerts = [DefenderLog.alert("alert-secret-1", at: start.addingTimeInterval(60)), DefenderLog.alert("low-1", at: start.addingTimeInterval(60), severity: "low")]
        service.incidents = [DefenderLog.incident("incident-secret-1", at: start.addingTimeInterval(120))]
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start))
        let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: Defender.adapter.alertLookBack))
        let found = try await Defender.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(Set(found.map(\.id)), [Defender.safeID("alert/", "alert-secret-1"), Defender.safeID("incident/", "incident-secret-1")])
        XCTAssertTrue(found.allSatisfy { $0.id.range(of: #"^(alert|incident)/[0-9a-f]{64}$"#, options: .regularExpression) != nil })
        let news = try XCTUnwrap(watch.take(found, for: connection.id, lookBack: Defender.adapter.alertLookBack))
        let note = AlertWatch.note(news, account: connection.name, skill: "defender", tool: Defender.adapter.watchedTool!)
        for leaked in ["secret", "victim", "Ransomware", "ignore-previous", "bbbbbbbb"] { XCTAssertFalse(note.contains(leaked), note) }
        XCTAssertTrue(note.contains(#"new="2""#), note)
    }

    /// Polls through the real AlertWatch until one returns nothing new with nothing left owed or to read on, at most
    /// `most`, saying what each delivered and the notices.
    private func poll(_ connection: ToolConnection, _ service: DefenderLog, from start: Date, most: Int = 20,
                      before: (Int) -> Void = { _ in }) async throws -> (delivered: [String], notices: [String], polls: Int) {
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start.addingTimeInterval(-60)))
        var delivered: [String] = [], notices: [String] = [], polls = 0
        while polls < most {
            polls += 1
            before(polls)
            let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: Defender.adapter.alertLookBack))
            let found: [ServiceAlert]
            do { found = try await Defender.adapter.alerts(since: since, connection: connection, access: service) } catch { continue }
            XCTAssertLessThanOrEqual(found.count, ServiceAlert.most)
            notices += found.map(\.id).filter { $0.hasPrefix("unchecked/") || $0.hasPrefix("unreadable/") }
            delivered += found.map(\.id).filter { $0.hasPrefix("alert/") }
            let idle = Defender.NewSecurityEvents.kept.withLock { $0[connection.id].map { $0.continuations.isEmpty && $0.owedFrom.isEmpty } ?? true }
            guard watch.take(found, for: connection.id, lookBack: Defender.adapter.alertLookBack) != nil || !idle else { break }
        }
        return (delivered, notices, polls)
    }

    private func kinds(_ notices: [String]) -> [String] { notices.map { $0.split(separator: "/").dropLast().joined(separator: "/") } }

    /// A burst bigger than one check returns, and more than one check may read, is all delivered over later checks,
    /// each once, with one notice that more follow.
    func testABurstBiggerThanOneCheckIsAllDeliveredEachOnce() async throws {
        for tokens in [false, true] {
            let connection = tenant()
            let service = DefenderLog()
            service.tokens = tokens
            let start = Date().addingTimeInterval(-2 * 3_600)
            let ids = (0..<1_500).map { String(format: "burst-%05d", $0) }
            service.alerts = ids.enumerated().map { DefenderLog.alert($1, at: start.addingTimeInterval(Double($0))) }
            let (delivered, notices, _) = try await poll(connection, service, from: start)
            XCTAssertEqual(delivered.count, ids.count, "each once")
            XCTAssertEqual(Set(delivered), Set(ids.map { Defender.safeID("alert/", $0) }), "every one, the oldest included")
            XCTAssertEqual(kinds(notices), ["unchecked/backlog"], "that more follow is told once")
            let kept = Defender.NewSecurityEvents.kept.withLock { $0[connection.id] }
            XCTAssertTrue(kept?.owedFrom.isEmpty == true && kept?.continuations.isEmpty == true, "nothing owed at the end")
        }
    }

    /// A check that fails for a reason that passes keeps nothing but how many in a row failed, so the next reads the
    /// same window again and returns what it would have.
    func testAFailedCheckKeepsOnlyItsFailureStreakAndRecovers() async throws {
        let connection = tenant()
        let trigger = Defender.NewSecurityEvents()
        let service = DefenderLog()
        let first = Date().addingTimeInterval(-10 * 3_600), later = Date()
        service.alerts = [DefenderLog.alert("before", at: first.addingTimeInterval(-60))]
        let found = try await trigger.alerts(since: first.addingTimeInterval(-3_600), on: client(connection, service), account: connection.id, now: first)
        XCTAssertEqual(found.count, 1)
        let before = try XCTUnwrap(Defender.NewSecurityEvents.kept.withLock { $0[connection.id] })
        XCTAssertEqual(before.readUntil["alerts"], first)
        service.alerts.append(DefenderLog.alert("during", at: first.addingTimeInterval(3_600)))
        service.mode = .busy
        do {
            _ = try await trigger.alerts(since: first.addingTimeInterval(-60), on: client(connection, service), account: connection.id, now: later)
            XCTFail("a passing failure holds the watch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("asked to wait 30 seconds"), error.localizedDescription)
        }
        let held = try XCTUnwrap(Defender.NewSecurityEvents.kept.withLock { $0[connection.id] })
        XCTAssertEqual(held.inARow.values.max(), 1)
        XCTAssertEqual(held.readUntil, before.readUntil)
        XCTAssertEqual(held.delivered, before.delivered)
        XCTAssertTrue(held.owedFrom.isEmpty && held.continuations.isEmpty && held.told.isEmpty)
        service.mode = .whole
        service.requests = []
        let recovered = try await trigger.alerts(since: first.addingTimeInterval(-20 * 3_600), on: client(connection, service), account: connection.id, now: later)
        XCTAssertEqual(recovered.map(\.id), [Defender.safeID("alert/", "during")], "the earlier one is not news again")
        let read = try XCTUnwrap(service.requests.first { $0.url?.path.hasSuffix("alerts_v2") == true })
        XCTAssertTrue(queryItems(read)["$filter"]?.contains("createdDateTime ge \(Entra.iso(first.addingTimeInterval(-6 * 3_600)))") == true, queryItems(read)["$filter"] ?? "")
        XCTAssertTrue(Defender.NewSecurityEvents.kept.withLock { $0[connection.id]?.inARow.isEmpty } == true)
    }

    /// A feed that cannot be read wakes the agents once while it stays so, and after holding back a few checks for one
    /// that might pass; reading again ends it, and a new failure wakes again.
    func testAnUnreadableFeedWakesOnceAndAgainOnlyAfterRecovering() async throws {
        let connection = tenant()
        let trigger = Defender.NewSecurityEvents()
        let service = DefenderLog()
        let since = Date().addingTimeInterval(-3_600)
        service.mode = .denied
        let told = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(Set(kinds(told.map(\.id))), ["unreadable/alerts", "unreadable/incidents"])
        XCTAssertTrue(told.allSatisfy { $0.time == since }, "dated at the window's start, so it moves nothing on")
        do { _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id); XCTFail("told once") } catch {}
        service.mode = .whole
        _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        service.mode = .busy
        for _ in 1...Defender.NewSecurityEvents.holdChecks {
            do { _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id); XCTFail("held back") } catch {}
        }
        let again = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(Set(kinds(again.map(\.id))), ["unreadable/alerts", "unreadable/incidents"], "a failure that lasts is told, once more")
    }

    /// A tenant without Defender is said once to be off, and security-events says why.
    func testATenantWithoutDefenderIsSaidOnceToBeOff() async throws {
        let connection = tenant()
        let trigger = Defender.NewSecurityEvents()
        let service = DefenderLog()
        service.unlicensed = true
        let since = Date().addingTimeInterval(-3_600)
        let first = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(Set(kinds(first.map(\.id))), ["unreadable/alerts", "unreadable/incidents"])
        let second = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertTrue(second.isEmpty, "told once: \(second)")
        let data = try await Defender.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        let text = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Off: high-severity alerts cannot be read: the tenant lacks Microsoft Defender XDR"), text)
    }

    /// What one check had no room for, and what it could not read, stays owed through a check that cannot read the
    /// feed, or reads it only in part, however far newer alerts moved the watch on, and is handed over, each once,
    /// when the feed reads again.
    func testOverflowADeniedOrTruncatedPollAndRecoveryStillDeliverEverythingOnce() async throws {
        for failure in [DefenderLog.Mode.denied, .elsewhere, .busy] {
            let connection = tenant()
            let service = DefenderLog()
            service.pageSize = 150
            let start = Date().addingTimeInterval(-12 * 3_600)
            let ids = (0..<900).map { String(format: "owed-%05d", $0) }
            service.alerts = ids.enumerated().map { index, id in
                DefenderLog.alert(id, at: start.addingTimeInterval(index < 700 ? Double(index) : Double(index - 699) * 120))
            }
            let (delivered, notices, _) = try await poll(connection, service, from: start) { poll in service.mode = poll == 2 ? failure : .whole }
            XCTAssertEqual(delivered.count, ids.count, "\(failure): each once")
            XCTAssertEqual(Set(delivered), Set(ids.map { Defender.safeID("alert/", $0) }), "\(failure): the oldest too")
            if failure == .denied { XCTAssertTrue(notices.contains { $0.hasPrefix("unreadable/alerts/") }, "\(failure): \(notices)") }
            if failure == .elsewhere { XCTAssertTrue(notices.contains { $0.hasPrefix("unchecked/alerts/") }, "\(failure): \(notices)") }
            let kept = Defender.NewSecurityEvents.kept.withLock { $0[connection.id] }
            XCTAssertTrue(kept?.owedFrom.isEmpty == true && kept?.continuations.isEmpty == true, "\(failure): nothing owed at the end")
        }
    }

    /// More alerts made at one moment than a check's page budget, and one after them: the watch goes on with the
    /// query it kept and its paging value, never restarting at that moment, so each is delivered exactly once.
    func testMoreTiedAlertsThanThePageBudgetAreEachDeliveredOnce() async throws {
        for tokens in [false, true] {
            let connection = tenant()
            let service = DefenderLog()
            service.tokens = tokens
            let start = Date().addingTimeInterval(-3 * 3_600), moment = start.addingTimeInterval(60)
            let tied = (0..<(Defender.watchPages * service.pageSize + 150)).map { String(format: "tied-%05d", $0) }
            service.alerts = tied.map { DefenderLog.alert($0, at: moment) } + [DefenderLog.alert("after-the-tie", at: moment.addingTimeInterval(1))]
            let (delivered, notices, polls) = try await poll(connection, service, from: start)
            XCTAssertLessThan(polls, 20, "it stops finding news")
            XCTAssertEqual(delivered.count, tied.count + 1, "each once")
            XCTAssertEqual(Set(delivered), Set((tied + ["after-the-tie"]).map { Defender.safeID("alert/", $0) }))
            XCTAssertEqual(kinds(notices), ["unchecked/backlog"], "that more follow is told once")
            let reads = service.requests.filter { $0.url?.path.hasSuffix("alerts_v2") == true }
            let resumed = try XCTUnwrap(reads.dropFirst(Defender.watchPages).first)
            XCTAssertNotNil(queryItems(resumed)[tokens ? "$skiptoken" : "$skip"])
            XCTAssertEqual(queryItems(resumed)["$filter"], queryItems(reads.first)["$filter"], "the same bounded query")
        }
    }

    /// A query that ends after a long continuation, while the watch moved on, leaves a boundary, so an alert made just
    /// after its end, read by no check yet, is still delivered.
    func testAQueryThatEndsAfterALongContinuationLeavesABoundary() async throws {
        let connection = tenant()
        let trigger = Defender.NewSecurityEvents()
        let service = DefenderLog()
        let client = client(connection, service)
        let first = Date().addingTimeInterval(-20 * 3_600)
        service.pageSize = 30
        service.alerts = (0..<(Defender.watchPages * service.pageSize * 3 + 20)).map { DefenderLog.alert(String(format: "q-%05d", $0), at: first.addingTimeInterval(-600 + Double($0) / 2)) }
        var caught = try await trigger.alerts(since: first.addingTimeInterval(-3_600), on: client, account: connection.id, now: first).map(\.id)
        let query = try XCTUnwrap(Defender.NewSecurityEvents.kept.withLock { $0[connection.id]?.continuations["alerts"] })
        XCTAssertEqual(query.until, first)
        service.alerts.append(DefenderLog.alert("just-after", at: first.addingTimeInterval(30)))
        var later = first
        for _ in 1...3 {
            later = later.addingTimeInterval(4 * 3_600)
            caught += try await trigger.alerts(since: later.addingTimeInterval(-600), on: client, account: connection.id, now: later).map(\.id)
        }
        XCTAssertFalse(caught.contains(Defender.safeID("alert/", "just-after")), "the query reads only its own window")
        XCTAssertEqual(Defender.NewSecurityEvents.kept.withLock { $0[connection.id]?.catchUp["alerts"] }, first.addingTimeInterval(-6 * 3_600))
        for check in 1...4 {
            caught += try await trigger.alerts(since: later.addingTimeInterval(-600), on: client, account: connection.id, now: later.addingTimeInterval(Double(check) * 300)).map(\.id)
        }
        XCTAssertEqual(caught.filter { $0 == Defender.safeID("alert/", "just-after") }.count, 1, "\(caught.count)")
        XCTAssertEqual(caught.filter { $0.hasPrefix("alert/") }.count, service.alerts.count, "each once")
    }

    /// A paging value Graph turns down is given up, said once, and its window read again from its start, so everything
    /// is still delivered, each once.
    func testARejectedPagingValueIsGivenUpAndItsWindowReadAgain() async throws {
        let connection = tenant()
        let service = DefenderLog()
        let start = Date().addingTimeInterval(-2 * 3_600)
        let ids = (0..<900).map { String(format: "rt-%05d", $0) }
        service.alerts = ids.enumerated().map { DefenderLog.alert($1, at: start.addingTimeInterval(Double($0))) }
        let (delivered, notices, _) = try await poll(connection, service, from: start) { poll in service.mode = poll == 2 ? .rejectToken : .whole }
        XCTAssertTrue(notices.contains { $0.hasPrefix("unchecked/alerts/") }, "\(notices)")
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map { Defender.safeID("alert/", $0) }))
        XCTAssertTrue(Defender.NewSecurityEvents.kept.withLock { $0[connection.id]?.owedFrom.isEmpty } == true)
    }

    /// security-events reads the same, says what it searched and when it was cut short, and what it does not watch.
    func testSecurityEventsSaysWhatItSearchedAndWhatItDidNotRead() async throws {
        let connection = tenant()
        let service = DefenderLog()
        let now = Date()
        service.alerts = (0..<1_050).map { DefenderLog.alert(String(format: "se-%05d", $0), at: now.addingTimeInterval(-3_000 + Double($0))) }
        service.incidents = [DefenderLog.incident("i1", at: now.addingTimeInterval(-600))]
        let data = try await Defender.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? ""
        XCTAssertTrue(text.contains("High alert from microsoftDefenderForEndpoint") && text.contains("High incident: Multi-stage incident"), text)
        XCTAssertTrue(text.contains("Searched: high-severity alerts") && text.contains("Searched: high-severity incidents"), text)
        XCTAssertTrue(text.contains("Cut short, with more not read: high-severity alerts"), text)
        XCTAssertTrue(text.contains("Not watched:") && text.contains("machine-actions"), text)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["complete"] as? Bool, false)
        XCTAssertEqual(service.requests.filter { $0.url?.path.hasSuffix("alerts_v2") == true }.count, Defender.eventsPages)
        let refused = try await callTool(Defender.adapter, "security-events", #"{"since":"2020-01-01T00:00:00Z"}"#, on: FakeService(), in: connection)
        XCTAssertTrue(refused.isError, "at most 30 days")
    }
}
