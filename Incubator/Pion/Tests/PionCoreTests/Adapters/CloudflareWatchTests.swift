import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

/// A Cloudflare account's audit log and Access logins as it answers them: the audit log a page at a time within the
/// window asked for, the logins by time; or refused, throttled, contradicting its own paging, turning down a later
/// page, or without Access.
final class CFLog: ServiceAccess, @unchecked Sendable {
    enum Mode { case whole, denied, busy, contradict, rejectPage, noAccess }
    let lock = NSLock()
    var entries: [[String: Any]] = []
    var logins: [[String: Any]] = []
    var mode = Mode.whole
    var requests: [URLRequest] = []
    static let account = "023e105f4ecef8ad9ca31a8372d0c353"

    static func time(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func entry(_ id: Int, at date: Date, action: String = "create", resource: String = "API_token", metadata: [String: Any]? = nil, result: Bool = true) -> [String: Any] {
        var entry: [String: Any] = ["id": String(format: "%08x-0000-4000-8000-%012x", id, id), "when": time(date), "action": ["type": action, "result": result],
                                    "actor": ["email": "mallory@secret.example", "ip": "198.51.100.66", "type": "user"], "interface": "API",
                                    "resource": ["type": resource, "id": "victim-resource-\(id)"]]
        if let metadata { entry["metadata"] = metadata }
        return entry
    }

    static func login(_ n: Int, at date: Date, email: String = "eve@secret.example", ip: String = "203.0.113.66", allowed: Bool = false) -> [String: Any] {
        ["user_email": email, "ip_address": ip, "app_domain": "wiki.secret.example", "app_uid": "a1", "action": "login", "allowed": allowed,
         "created_at": time(date), "ray_id": "ray\(n)", "connection": "okta"]
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let mode = lock.withLock { requests.append(request); return self.mode }
        let url = request.url!
        func answer(_ status: Int, _ body: Any) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!)
        }
        switch mode {
        case .denied: return try answer(403, ["success": false, "errors": [["code": 10000, "message": "Authentication error"]]])
        case .busy: return try answer(429, ["success": false, "errors": [["code": 971, "message": "Please wait and consider throttling your request speed"]]])
        default: break
        }
        let query = queryItems(request)
        switch url.path {
        case "/client/v4/accounts/\(Self.account)/audit_logs":
            let since = query["since"].flatMap(ServiceAlert.time) ?? .distantPast, before = query["before"].flatMap(ServiceAlert.time) ?? .distantFuture
            XCTAssertEqual(query["direction"], "desc")
            let matching = lock.withLock { entries }.filter { ServiceAlert.time($0["when"] as? String).map { $0 >= since && $0 <= before } ?? false }
                .sorted { (($0["when"] as! String), $0["id"] as! String) > (($1["when"] as! String), $1["id"] as! String) }
            let size = Int(query["per_page"] ?? "100") ?? 100, page = Int(query["page"] ?? "1") ?? 1
            if page > 1, mode == .rejectPage { return try answer(400, ["success": false, "errors": [["code": 1001, "message": "Invalid page"]]]) }
            let slice = Array(matching.dropFirst((page - 1) * size).prefix(size))
            let pages = (matching.count + size - 1) / size
            return try answer(200, ["success": true, "errors": [], "result": slice,
                                    "result_info": ["page": page > 1 && mode == .contradict ? page + 1 : page, "per_page": size, "count": slice.count, "total_count": matching.count, "total_pages": pages]])
        case "/client/v4/accounts/\(Self.account)/access/logs/access_requests":
            if mode == .noAccess { return try answer(403, ["success": false, "errors": [["code": 12130, "message": "Access is not enabled for this account"]]]) }
            let since = query["since"].flatMap(ServiceAlert.time) ?? .distantPast, until = query["until"].flatMap(ServiceAlert.time) ?? .distantFuture
            let matching = lock.withLock { logins }.filter { ServiceAlert.time($0["created_at"] as? String).map { $0 >= since && $0 <= until } ?? false }
                .sorted { (($0["created_at"] as! String), $0["ray_id"] as! String) > (($1["created_at"] as! String), $1["ray_id"] as! String) }
            return try answer(200, ["success": true, "errors": [], "result": Array(matching.prefix(Int(query["limit"] ?? "25") ?? 25))])
        default:
            return try answer(404, ["success": false, "errors": [["code": 7003, "message": "No route for the URI"]]])
        }
    }
}

final class CloudflareWatchTests: XCTestCase {
    private func connection() -> ToolConnection {
        try! Cloudflare.preset.makeConnection(name: "Cloudflare — Kestrel", values: ["account": CFLog.account])
    }

    private func client(_ connection: ToolConnection, _ access: any ServiceAccess) -> ServiceClient {
        ServiceClient(base: connection.endpoint, access: access, settings: connection.settings ?? [:], account: connection.id)
    }

    private func entryID(_ id: Int) -> String { Cloudflare.safeID("audit/", String(format: "%08x-0000-4000-8000-%012x", id, id)) }

    private func kinds(_ notices: [String]) -> [String] { notices.map { $0.split(separator: "/").dropLast().joined(separator: "/") }.sorted() }

    private func item(_ object: [String: Any]) throws -> Cloudflare.Item { try JSONDecoder().decode(Cloudflare.Item.self, from: JSONSerialization.data(withJSONObject: object)) }

    /// Which audit log entries are high-risk, by the words of their action, resource and what they changed.
    func testTheWatchKnowsHighRiskChangesFromTheirOwnWords() throws {
        let now = Date()
        let cases: [([String: Any], String?)] = [
            (CFLog.entry(1, at: now), "API token made"),
            (CFLog.entry(2, at: now, action: "roll", resource: "API_token"), "API token rolled"),
            (CFLog.entry(3, at: now, action: "add", resource: "member"), "member added or roles changed"),
            (CFLog.entry(4, at: now, action: "rec_set", resource: "DNS_record", metadata: ["zone_name": "kestrel.example", "name": "kestrel.example", "type": "A"]), "DNS change on a zone's apex"),
            (CFLog.entry(5, at: now, action: "rec_add", resource: "DNS_record", metadata: ["zone_name": "kestrel.example", "name": "kestrel.example", "type": "MX"]), "DNS change on an MX or NS record"),
            (CFLog.entry(6, at: now, action: "rec_add", resource: "DNS_record", metadata: ["zone_name": "kestrel.example", "name": "www.kestrel.example", "type": "A"]), nil),
            (CFLog.entry(7, at: now, action: "rec_del", resource: "DNS_record"), "DNS change whose record is not named"),
            (CFLog.entry(8, at: now, action: "delete", resource: "firewall_rule"), "firewall or WAF rule turned off or deleted"),
            (CFLog.entry(9, at: now, action: "update", resource: "ruleset", metadata: ["enabled": false]), "firewall or WAF rule turned off or deleted"),
            (CFLog.entry(10, at: now, action: "update", resource: "ruleset", metadata: ["enabled": true]), nil),
            (CFLog.entry(11, at: now, action: "update", resource: "access_policy"), "Access policy or application changed"),
            (CFLog.entry(12, at: now, action: "delete", resource: "access_rule"), "firewall or WAF rule turned off or deleted"),
            (CFLog.entry(13, at: now, action: "update", resource: "gateway_rule", metadata: ["enabled": false]), "Gateway rule turned off or deleted"),
            (CFLog.entry(14, at: now, action: "revoke", resource: "device"), "WARP device revoked"),
            (CFLog.entry(15, at: now, action: "unrevoke", resource: "device"), "WARP device unrevoked"),
            (CFLog.entry(16, at: now, action: "create", resource: "tunnel"), "tunnel made"),
            (CFLog.entry(17, at: now, action: "change_setting", resource: "zone"), nil),
            (CFLog.entry(18, at: now, result: false), nil),
        ]
        for (entry, kind) in cases {
            XCTAssertEqual(Cloudflare.risk(try item(entry))?.kind, kind, "\(entry["action"] ?? "") \(entry["resource"] ?? "")")
        }
    }

    /// Undoing is never read as doing: the action is read word by word, inverse verbs first, and a state the entry gives
    /// for what the change left is preferred to its verb.
    func testInverseVerbsAndStatedResultsAreReadAsWhatTheyDo() throws {
        let now = Date()
        func kind(_ action: String, _ resource: String, new: [String: Any]? = nil, newValue: String? = nil) throws -> String? {
            var entry = CFLog.entry(1, at: now, action: action, resource: resource)
            if let new { entry["newValueJson"] = new }
            if let newValue { entry["newValue"] = newValue }
            return Cloudflare.risk(try item(entry))?.kind
        }
        let off = "firewall or WAF rule turned off or deleted"
        XCTAssertEqual(try kind("pause", "firewall_rule"), off)
        XCTAssertNil(try kind("unpause", "firewall_rule"), "unpause is not pause")
        XCTAssertEqual(try kind("disable", "ruleset"), off)
        XCTAssertNil(try kind("enable", "ruleset"), "enable is not disable")
        XCTAssertEqual(try kind("disableRule", "ruleset"), off)
        XCTAssertNil(try kind("enableRule", "ruleset"))
        XCTAssertEqual(try kind("delete", "firewall_rule"), off)
        XCTAssertNil(try kind("restore", "firewall_rule"), "restore is not delete")
        XCTAssertNil(try kind("undelete", "firewall_rule"))
        XCTAssertNil(try kind("unblock", "access_rule"), "unblock is neither turning off nor deleting")
        XCTAssertEqual(try kind("revoke", "device"), "WARP device revoked")
        XCTAssertEqual(try kind("unrevoke", "device"), "WARP device unrevoked")
        XCTAssertEqual(try kind("disable", "gateway_rule"), "Gateway rule turned off or deleted")
        XCTAssertNil(try kind("enable", "gateway_rule"))
        XCTAssertEqual(try kind("rec_del", "DNS_record"), "DNS change whose record is not named")
        XCTAssertNil(try kind("pause", "firewall_rule", new: ["paused": false]), "the stated result wins over the verb")
        XCTAssertEqual(try kind("update", "firewall_rule", new: ["paused": true]), off)
        XCTAssertEqual(try kind("update", "ruleset", newValue: #"{"enabled":false}"#), off)
        XCTAssertNil(try kind("disable", "ruleset", newValue: #"{"enabled":true}"#))
    }

    /// The note that wakes an agent carries counts and times only: no ID, name, address or text Cloudflare gave.
    func testWakesCarryOnlyCountsTimesAndHashedIDs() async throws {
        let connection = connection()
        let service = CFLog()
        let start = Date().addingTimeInterval(-600)
        service.entries = [CFLog.entry(31_337, at: start.addingTimeInterval(60))]
        service.logins = (0..<12).map { CFLog.login($0, at: start.addingTimeInterval(120)) }
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start))
        let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: Cloudflare.adapter.alertLookBack))
        let found = try await Cloudflare.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(found.count, 2, "\(found.map(\.id))")
        XCTAssertTrue(found.allSatisfy { $0.id.range(of: #"^(audit|access)/[0-9a-f]{64}$"#, options: .regularExpression) != nil }, "\(found.map(\.id))")
        let news = try XCTUnwrap(watch.take(found, for: connection.id, lookBack: Cloudflare.adapter.alertLookBack))
        let note = AlertWatch.note(news, account: connection.name, skill: "cloudflare", tool: Cloudflare.adapter.watchedTool!)
        for leaked in ["31337", "7a69", "secret", "mallory", "198.51.100", "203.0.113", "victim", "eve@"] { XCTAssertFalse(note.contains(leaked), note) }
        XCTAssertTrue(note.contains(#"new="2""#) && note.contains(#"tool="security-events""#), note)
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "api.cloudflare.com" && $0.httpMethod == "GET" })
    }

    private func poll(_ connection: ToolConnection, _ service: CFLog, from start: Date, most: Int = 20, page: Int = 100,
                      before: (Int) -> Void = { _ in }) async throws -> (delivered: [String], notices: [String], polls: Int) {
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start.addingTimeInterval(-60)))
        var delivered: [String] = [], notices: [String] = [], polls = 0
        while polls < most {
            polls += 1
            before(polls)
            let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: Cloudflare.adapter.alertLookBack))
            let found: [ServiceAlert]
            do {
                found = try await Cloudflare.$watchPage.withValue(page) {
                    try await Cloudflare.$pause.withValue({ _ in }) { try await Cloudflare.adapter.alerts(since: since, connection: connection, access: service) }
                }
            } catch { continue }
            XCTAssertLessThanOrEqual(found.count, ServiceAlert.most)
            notices += found.map(\.id).filter { $0.hasPrefix("unchecked/") || $0.hasPrefix("unreadable/") }
            delivered += found.map(\.id).filter { $0.hasPrefix("audit/") }
            let idle = Cloudflare.NewSecurityEvents.kept.withLock { $0[connection.id].map { $0.continuations.isEmpty && $0.owedFrom.isEmpty } ?? true }
            guard watch.take(found, for: connection.id, lookBack: Cloudflare.adapter.alertLookBack) != nil || !idle else { break }
        }
        return (delivered, notices, polls)
    }

    /// A burst bigger than one check returns, and more than one check may read, is all delivered over later checks,
    /// each once, with one notice that more follow.
    func testABurstBiggerThanOneCheckIsAllDeliveredEachOnce() async throws {
        let connection = connection()
        let service = CFLog()
        let start = Date().addingTimeInterval(-2 * 3_600)
        let ids = (0..<1_500).map { 100_000 + $0 }
        service.entries = ids.enumerated().map { CFLog.entry($1, at: start.addingTimeInterval(Double($0))) }
        let (delivered, notices, _) = try await poll(connection, service, from: start)
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map(entryID)), "every one, the oldest included")
        XCTAssertEqual(kinds(notices), ["unchecked/backlog"], "that more follow is told once")
        let kept = Cloudflare.NewSecurityEvents.kept.withLock { $0[connection.id] }
        XCTAssertTrue(kept?.owedFrom.isEmpty == true && kept?.continuations.isEmpty == true, "nothing owed at the end")
    }

    /// A check that fails for a reason that passes keeps nothing but how many in a row failed, so the next reads the
    /// same window again and returns what it would have.
    func testAFailedCheckKeepsOnlyItsFailureStreakAndRecovers() async throws {
        let connection = connection()
        let trigger = Cloudflare.NewSecurityEvents()
        let service = CFLog()
        let first = Date().addingTimeInterval(-10 * 3_600), later = Date()
        service.entries = [CFLog.entry(1, at: first.addingTimeInterval(-60))]
        let found = try await trigger.alerts(since: first.addingTimeInterval(-3_600), on: client(connection, service), account: connection.id, now: first)
        XCTAssertEqual(found.count, 1)
        let before = try XCTUnwrap(Cloudflare.NewSecurityEvents.kept.withLock { $0[connection.id] })
        XCTAssertEqual(before.readUntil["audit"], first)
        service.entries.append(CFLog.entry(2, at: first.addingTimeInterval(3_600)))
        service.mode = .busy
        do {
            _ = try await Cloudflare.$pause.withValue({ _ in }) {
                try await trigger.alerts(since: first.addingTimeInterval(-60), on: client(connection, service), account: connection.id, now: later)
            }
            XCTFail("a passing failure holds the watch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rate limit"), error.localizedDescription)
        }
        let held = try XCTUnwrap(Cloudflare.NewSecurityEvents.kept.withLock { $0[connection.id] })
        XCTAssertEqual(held.inARow.values.max(), 1)
        XCTAssertEqual(held.readUntil, before.readUntil)
        XCTAssertEqual(held.delivered, before.delivered)
        XCTAssertTrue(held.owedFrom.isEmpty && held.continuations.isEmpty && held.told.isEmpty)
        service.mode = .whole
        service.requests = []
        let recovered = try await trigger.alerts(since: first.addingTimeInterval(-20 * 3_600), on: client(connection, service), account: connection.id, now: later)
        XCTAssertEqual(recovered.map(\.id), [entryID(2)], "the earlier one is not news again")
        let read = try XCTUnwrap(service.requests.first { $0.url?.path.hasSuffix("/audit_logs") == true })
        XCTAssertEqual(queryItems(read)["since"], Entra.iso(first.addingTimeInterval(-6 * 3_600)))
        XCTAssertTrue(Cloudflare.NewSecurityEvents.kept.withLock { $0[connection.id]?.inARow.isEmpty } == true)
    }

    /// A feed that cannot be read wakes the agents once while it stays so, and after holding back a few checks for one
    /// that might pass; reading again ends it, and a new failure wakes again.
    func testAnUnreadableFeedWakesOnceAndAgainOnlyAfterRecovering() async throws {
        let connection = connection()
        let trigger = Cloudflare.NewSecurityEvents()
        let service = CFLog()
        let since = Date().addingTimeInterval(-3_600)
        service.mode = .denied
        let told = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(kinds(told.map(\.id)), ["unreadable/access", "unreadable/audit"])
        XCTAssertTrue(told.allSatisfy { $0.time == since }, "dated at the window's start, so it moves nothing on")
        do { _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id); XCTFail("told once") } catch {}
        service.mode = .whole
        _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        service.mode = .busy
        try await Cloudflare.$pause.withValue({ _ in }) {
            for _ in 1...Cloudflare.NewSecurityEvents.holdChecks {
                do { _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id); XCTFail("held back") } catch {}
            }
            let again = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
            XCTAssertEqual(kinds(again.map(\.id)), ["unreadable/access", "unreadable/audit"], "a failure that lasts is told, once more")
        }
        service.mode = .denied
        let data = try await Cloudflare.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        let text = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Nothing could be read") && text.contains("Account › Account Settings › Read") && text.contains("Account › Zero Trust › Read"), text)
    }

    /// An account without Access is said once to have its logins off, and the audit log is still watched.
    func testAnAccountWithoutAccessIsSaidOnceToBeOff() async throws {
        let connection = connection()
        let trigger = Cloudflare.NewSecurityEvents()
        let service = CFLog()
        service.mode = .noAccess
        let since = Date().addingTimeInterval(-3_600)
        service.entries = [CFLog.entry(5, at: since.addingTimeInterval(60))]
        let first = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(kinds(first.filter { !$0.id.hasPrefix("audit/") }.map(\.id)), ["unreadable/access"])
        XCTAssertTrue(first.contains { $0.id == entryID(5) })
        let second = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertTrue(second.isEmpty, "told once")
        let events = try await Cloudflare.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        let text = ((try JSONSerialization.jsonObject(with: events) as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Off: bursts of blocked Access logins cannot be read") && text.contains("Searched: high-risk changes"), text)
    }

    /// What one check had no room for, and what it could not read, stays owed through a check that cannot read the
    /// feed, or reads it only in part, however far newer entries moved the watch on, and is handed over, each once,
    /// when the feed reads again.
    func testOverflowADeniedOrTruncatedPollAndRecoveryStillDeliverEverythingOnce() async throws {
        for failure in [CFLog.Mode.denied, .contradict, .busy] {
            let connection = connection()
            let service = CFLog()
            let start = Date().addingTimeInterval(-12 * 3_600)
            let ids = (0..<900).map { 200_000 + $0 }
            service.entries = ids.enumerated().map { index, id in
                CFLog.entry(id, at: start.addingTimeInterval(index < 700 ? Double(index) : Double(index - 699) * 120))
            }
            let (delivered, notices, _) = try await poll(connection, service, from: start, page: 150) { poll in service.mode = poll == 2 ? failure : .whole }
            XCTAssertEqual(delivered.count, ids.count, "\(failure): each once")
            XCTAssertEqual(Set(delivered), Set(ids.map(entryID)), "\(failure): the oldest too")
            if failure == .denied { XCTAssertTrue(notices.contains { $0.hasPrefix("unreadable/audit/") }, "\(failure): \(notices)") }
            if failure == .contradict { XCTAssertTrue(notices.contains { $0.hasPrefix("unchecked/audit/") }, "\(failure): \(notices)") }
            let kept = Cloudflare.NewSecurityEvents.kept.withLock { $0[connection.id] }
            XCTAssertTrue(kept?.owedFrom.isEmpty == true && kept?.continuations.isEmpty == true, "\(failure): nothing owed at the end")
        }
    }

    /// More entries at one moment than a check's page budget, and one after them: the watch goes on with the query it
    /// kept and its page, never restarting at that moment, so each is delivered exactly once.
    func testMoreTiedEntriesThanThePageBudgetAreEachDeliveredOnce() async throws {
        let connection = connection()
        let service = CFLog()
        let start = Date().addingTimeInterval(-3 * 3_600), moment = start.addingTimeInterval(60)
        let tied = (0..<(Cloudflare.watchPages * 100 + 150)).map { 300_000 + $0 }
        service.entries = tied.map { CFLog.entry($0, at: moment) } + [CFLog.entry(399_999, at: moment.addingTimeInterval(1))]
        let (delivered, notices, polls) = try await poll(connection, service, from: start)
        XCTAssertLessThan(polls, 20, "it stops finding news")
        XCTAssertEqual(delivered.count, tied.count + 1, "each once")
        XCTAssertEqual(Set(delivered), Set((tied + [399_999]).map(entryID)))
        XCTAssertEqual(kinds(notices), ["unchecked/backlog"], "that more follow is told once")
        let reads = service.requests.filter { $0.url?.path.hasSuffix("/audit_logs") == true }.map(queryItems)
        let resumed = try XCTUnwrap(reads.dropFirst(Cloudflare.watchPages).first)
        XCTAssertEqual(resumed["page"], String(Cloudflare.watchPages + 1))
        XCTAssertEqual(resumed["since"], reads.first?["since"], "the same bounded query")
        XCTAssertEqual(resumed["before"], reads.first?["before"], "the same bounded query")
    }

    /// A search that ends after a long continuation, while the watch moved on, leaves a boundary, so an entry just after
    /// its end, read by no check yet, is still delivered.
    func testASearchThatEndsAfterALongContinuationLeavesABoundary() async throws {
        let connection = connection()
        let trigger = Cloudflare.NewSecurityEvents()
        let service = CFLog()
        let client = client(connection, service)
        let first = Date().addingTimeInterval(-20 * 3_600)
        func check(since: Date, now: Date) async throws -> [String] {
            try await Cloudflare.$watchPage.withValue(30) { try await trigger.alerts(since: since, on: client, account: connection.id, now: now).map(\.id) }
        }
        service.entries = (0..<(Cloudflare.watchPages * 30 * 3 + 20)).map { CFLog.entry(400_000 + $0, at: first.addingTimeInterval(-600 + Double($0) / 2)) }
        var caught = try await check(since: first.addingTimeInterval(-3_600), now: first)
        let search = try XCTUnwrap(Cloudflare.NewSecurityEvents.kept.withLock { $0[connection.id]?.continuations["audit"] })
        XCTAssertEqual(search.until, first)
        service.entries.append(CFLog.entry(499_999, at: first.addingTimeInterval(30)))
        var later = first
        for _ in 1...3 {
            later = later.addingTimeInterval(4 * 3_600)
            caught += try await check(since: later.addingTimeInterval(-600), now: later)
        }
        XCTAssertFalse(caught.contains(entryID(499_999)), "the search reads only its own window")
        XCTAssertEqual(Cloudflare.NewSecurityEvents.kept.withLock { $0[connection.id]?.catchUp["audit"] }, first.addingTimeInterval(-6 * 3_600))
        for step in 1...4 {
            caught += try await check(since: later.addingTimeInterval(-600), now: later.addingTimeInterval(Double(step) * 300))
        }
        XCTAssertEqual(caught.filter { $0 == entryID(499_999) }.count, 1, "\(caught.count)")
        XCTAssertEqual(caught.filter { $0.hasPrefix("audit/") }.count, service.entries.count, "each once")
    }

    /// A later page Cloudflare turns down is given up, said once, and its window read again from its start, so
    /// everything is still delivered, each once.
    func testARejectedPageIsGivenUpAndItsWindowReadAgain() async throws {
        let connection = connection()
        let service = CFLog()
        let start = Date().addingTimeInterval(-2 * 3_600)
        let ids = (0..<900).map { 500_000 + $0 }
        service.entries = ids.enumerated().map { CFLog.entry($1, at: start.addingTimeInterval(Double($0))) }
        let (delivered, notices, _) = try await poll(connection, service, from: start) { poll in service.mode = poll == 2 ? .rejectPage : .whole }
        XCTAssertTrue(notices.contains { $0.hasPrefix("unchecked/audit/") }, "\(notices)")
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map(entryID)))
        XCTAssertTrue(Cloudflare.NewSecurityEvents.kept.withLock { $0[connection.id]?.owedFrom.isEmpty } == true)
    }

    /// Blocked logins are a burst once ten come from one address, or for one person, within an hour: told once, and not
    /// again as more arrive in that hour; allowed logins never count.
    func testBlockedLoginBurstsAreToldOnceAtTheThreshold() async throws {
        let connection = connection()
        let trigger = Cloudflare.NewSecurityEvents()
        let service = CFLog()
        let hour = floor(Date().addingTimeInterval(-3 * 3_600).timeIntervalSince1970 / 3_600) * 3_600
        let since = Date(timeIntervalSince1970: hour - 600)
        service.logins = (0..<9).map { CFLog.login($0, at: Date(timeIntervalSince1970: hour + Double($0) * 60), email: "user\($0)@secret.example") }
            + (0..<5).map { CFLog.login(100 + $0, at: Date(timeIntervalSince1970: hour + 1_000 + Double($0)), email: "user\($0)@secret.example", allowed: true) }
        let quiet = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertTrue(quiet.isEmpty, "nine blocked and five allowed are no burst: \(quiet.map(\.id))")
        service.logins.append(CFLog.login(9, at: Date(timeIntervalSince1970: hour + 1_500), email: "user9@secret.example"))
        let burst = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(burst.count, 1)
        XCTAssertTrue(burst[0].id.hasPrefix("access/") && burst[0].time == Date(timeIntervalSince1970: hour + 1_500), "dated at the login that made it a burst")
        service.logins += (10..<15).map { CFLog.login($0, at: Date(timeIntervalSince1970: hour + 1_600 + Double($0))) }
        let more = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertTrue(more.isEmpty, "the same burst is not news again")
        let events = try await Cloudflare.adapter.run("security-events", arguments: Data(#"{"since":"\#(Entra.iso(since))"}"#.utf8), connection: connection, access: service)
        let text = ((try JSONSerialization.jsonObject(with: events) as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Burst of blocked Access logins: 15 blocked from 203.0.113.66"), text)
    }

    /// security-events reads the same, says what it searched and when it was cut short, and what it does not watch.
    func testSecurityEventsSaysWhatItSearchedAndWhatItDidNotRead() async throws {
        let connection = connection()
        let service = CFLog()
        let now = Date()
        service.entries = (0..<(Cloudflare.eventsPages * 100 + 50)).map { CFLog.entry(600_000 + $0, at: now.addingTimeInterval(-3_000 + Double($0) / 2)) }
            + [CFLog.entry(77, at: now.addingTimeInterval(-60), action: "add", resource: "member")]
        let data = try await Cloudflare.$watchPage.withValue(100) {
            try await Cloudflare.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        }
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? ""
        XCTAssertTrue(text.contains("Member added or roles changed:") && text.contains("API token made:") && text.contains("by mallory@secret.example"), text)
        XCTAssertTrue(text.contains("Searched: high-risk changes in the account audit log") && text.contains("Searched: bursts of blocked Access logins"), text)
        XCTAssertTrue(text.contains("Cut short, with more not read: high-risk changes in the account audit log"), text)
        XCTAssertTrue(text.contains("Not watched:") && text.contains("whether a change to an Access policy loosened it"), text)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["complete"] as? Bool, false)
        XCTAssertEqual(service.requests.filter { $0.url?.path.hasSuffix("/audit_logs") == true }.count, Cloudflare.eventsPages)
        let refused = try await callTool(Cloudflare.adapter, "security-events", #"{"since":"2020-01-01T00:00:00Z"}"#, on: FakeService(), in: connection)
        XCTAssertTrue(refused.isError, "at most 30 days")
    }
}
