import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

/// A SentinelOne console's threats, activity log and disconnected agents as it answers them: a page at a time, each
/// page's cursor good only with the query it came from; or refused, throttled, giving a cursor Pion will not follow, or
/// turning down a cursor.
final class S1Log: ServiceAccess, @unchecked Sendable {
    enum Mode { case whole, denied, busy, unfollowable, rejectCursor }
    let lock = NSLock()
    var threats: [[String: Any]] = []
    var activities: [[String: Any]] = []
    var types: [[String: Any]] = [
        ["id": 1001, "action": "Agent Disconnected From Network", "descriptionTemplate": "{{ username }} disconnected {{ computer_name }} from network"],
        ["id": 1002, "action": "Agent Reconnected To Network", "descriptionTemplate": "{{ username }} reconnected {{ computer_name }} to network"],
        ["id": 2001, "action": "Threat Killed", "descriptionTemplate": "{{ username }} issued kill command for threat {{ threat_name }}"],
        ["id": 2002, "action": "Threat Quarantined", "descriptionTemplate": "{{ username }} quarantined threat {{ threat_name }}"],
        ["id": 90, "action": "Agent Uninstalled", "descriptionTemplate": "Agent {{ computer_name }} uninstalled"],
    ]
    var disconnected: [String] = []
    var mode = Mode.whole
    var pageSize: Int? = nil
    var requests: [URLRequest] = []

    static func time(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func threat(_ id: Int, at date: Date, confidence: String? = "malicious", status: String? = "unresolved") -> [String: Any] {
        var info: [String: Any] = ["threatName": "Mimikatz by ignore-previous-instructions", "classification": "Hacktool", "createdAt": time(date), "mitigationStatus": "not_mitigated"]
        if let confidence { info["confidenceLevel"] = confidence }
        if let status { info["incidentStatus"] = status }
        return ["id": String(id), "threatInfo": info, "agentRealtimeInfo": ["agentId": "5550001", "agentComputerName": "victim-laptop"]]
    }

    static func activity(_ id: Int, at date: Date, type: Int, user: String? = "4242") -> [String: Any] {
        var entry: [String: Any] = ["id": String(id), "activityType": type, "createdAt": time(date), "primaryDescription": "admin@secret.example did something to victim-laptop",
                                    "agentId": "5550001", "data": ["username": "admin@secret.example"]]
        if let user { entry["userId"] = user }
        return entry
    }

    /// The query a cursor belongs to: every value but the cursor and the page size.
    static func canonical(_ query: [String: String]) -> String {
        query.filter { $0.key != "cursor" && $0.key != "limit" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let mode = lock.withLock { requests.append(request); return self.mode }
        let url = request.url!
        func answer(_ status: Int, _ body: Any) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!)
        }
        switch mode {
        case .denied: return try answer(403, ["errors": [["code": 4030010, "title": "Forbidden", "detail": "Action is not allowed"]]])
        case .busy: return try answer(429, ["errors": [["code": 4290010, "title": "Too Many Requests"]]])
        case .whole, .unfollowable, .rejectCursor: break
        }
        let query = queryItems(request)
        func page(_ matching: [[String: Any]]) throws -> (Data, HTTPURLResponse) {
            var start = 0
            if let cursor = query["cursor"] {
                if mode == .rejectCursor { return try answer(400, ["errors": [["code": 4000010, "title": "Validation Error", "detail": "cursor is invalid"]]]) }
                let parts = String(decoding: Data(base64Encoded: cursor) ?? Data(), as: UTF8.self).split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[1] == Self.canonical(query) else {
                    XCTFail("a cursor sent with another query: \(Self.canonical(query))")
                    return try answer(400, ["errors": [["title": "mismatched cursor"]]])
                }
                start = Int(parts[0]) ?? 0
            }
            let size = min(Int(query["limit"] ?? "100") ?? 100, lock.withLock { pageSize } ?? .max)
            let items = Array(matching.dropFirst(start).prefix(size))
            var pagination: [String: Any] = ["totalItems": matching.count]
            if start + items.count < matching.count {
                pagination["nextCursor"] = mode == .unfollowable ? "not a cursor" : Data("\(start + items.count)|\(Self.canonical(query))".utf8).base64EncodedString()
            } else { pagination["nextCursor"] = NSNull() }
            return try answer(200, ["data": items, "pagination": pagination])
        }
        let since = query["createdAt__gte"].flatMap(ServiceAlert.time) ?? .distantPast, until = query["createdAt__lte"].flatMap(ServiceAlert.time) ?? .distantFuture
        func newest(_ items: [[String: Any]], time: ([String: Any]) -> String?) -> [[String: Any]] {
            items.filter { item in time(item).flatMap(ServiceAlert.time).map { $0 >= since && $0 <= until } ?? false }
                .sorted { (time($0) ?? "", $0["id"] as! String) > (time($1) ?? "", $1["id"] as! String) }
        }
        switch url.path {
        case "/web/api/v2.1/threats":
            XCTAssertEqual(query["incidentStatuses"], "unresolved")
            return try page(newest(lock.withLock { threats }) { ($0["threatInfo"] as? [String: Any])?["createdAt"] as? String })
        case "/web/api/v2.1/activities/types":
            return try answer(200, ["data": lock.withLock { types }])
        case "/web/api/v2.1/activities":
            let asked = Set((query["activityTypes"] ?? "").split(separator: ",").compactMap { Int($0) })
            return try page(newest(lock.withLock { activities }.filter { asked.contains($0["activityType"] as? Int ?? -1) }) { $0["createdAt"] as? String })
        case "/web/api/v2.1/agents":
            XCTAssertEqual(query["networkStatuses"], "disconnected,disconnecting")
            let agents = lock.withLock { disconnected }.map { ["id": $0, "computerName": "victim-laptop", "networkStatus": "disconnected"] }
            return try answer(200, ["data": agents, "pagination": ["totalItems": agents.count, "nextCursor": NSNull()]])
        default:
            return try answer(404, ["errors": [["title": "Not Found"]]])
        }
    }
}

final class SentinelOneWatchTests: XCTestCase {
    private func console() -> ToolConnection {
        try! SentinelOne.preset.makeConnection(name: "SentinelOne — Kestrel", values: ["console": "usea1-kestrel.sentinelone.net"])
    }

    private func client(_ connection: ToolConnection, _ access: any ServiceAccess) -> ServiceClient {
        ServiceClient(base: connection.endpoint, access: access, settings: connection.settings ?? [:], account: connection.id)
    }

    private func threatID(_ id: Int) -> String { SentinelOne.safeID("threat/", String(id)) }

    func testTheWatchKeepsUnresolvedMaliciousAndSuspiciousThreatsAndUnknownConfidence() async throws {
        let connection = console()
        let service = S1Log()
        let now = Date(), at = now.addingTimeInterval(-600)
        service.threats = [S1Log.threat(1, at: at), S1Log.threat(2, at: at, confidence: "suspicious"), S1Log.threat(3, at: at, confidence: nil),
                           S1Log.threat(4, at: at, confidence: "n/a"), S1Log.threat(5, at: at, status: "resolved"), S1Log.threat(6, at: now.addingTimeInterval(-7_200))]
        let read = await SentinelOne.readFeed(.threats, client(connection, service), since: now.addingTimeInterval(-3_600), until: now, pages: 2)
        XCTAssertEqual(Set(read.events.map(\.id)), Set([1, 2, 3].map(threatID)))
        XCTAssertTrue(read.complete)
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "usea1-kestrel.sentinelone.net" })
    }

    /// The activity log feed reads only the types that say a network disconnect or a threat mitigation, and only what a
    /// person issued.
    func testActionsAreDisconnectsAndMitigationsAPersonIssued() async throws {
        let connection = console()
        let service = S1Log()
        let now = Date(), at = now.addingTimeInterval(-600)
        service.activities = [S1Log.activity(11, at: at, type: 1001), S1Log.activity(12, at: at, type: 2001), S1Log.activity(13, at: at, type: 2001, user: nil),
                              S1Log.activity(14, at: at, type: 1002), S1Log.activity(15, at: at, type: 90)]
        let read = await SentinelOne.readFeed(.actions, client(connection, service), since: now.addingTimeInterval(-3_600), until: now, pages: 2)
        XCTAssertEqual(Set(read.events.map(\.id)), Set(["11", "12"].map { SentinelOne.safeID("activity/", $0) }))
        XCTAssertEqual(read.events.first { $0.id == SentinelOne.safeID("activity/", "11") }?.kind, "network disconnect by a person")
        let asked = queryItems(service.requests.last { $0.url?.path == "/web/api/v2.1/activities" })
        XCTAssertEqual(asked["activityTypes"], "1001,2001,2002")
        let (disconnect, mitigation) = SentinelOne.watchedTypes(try JSONDecoder().decode([SentinelOne.ActivityType].self, from: JSONSerialization.data(withJSONObject: service.types)))
        XCTAssertEqual(disconnect, [1001])
        XCTAssertEqual(mitigation, [2001, 2002])
    }

    /// A console whose activity types name none Pion recognises says once that the feed is off.
    func testAConsoleWithoutRecognisedActivityTypesIsSaidOnceToBeOff() async throws {
        let connection = console()
        let trigger = SentinelOne.NewSecurityEvents()
        let service = S1Log()
        service.types = [["id": 90, "action": "Agent Uninstalled"]]
        let since = Date().addingTimeInterval(-3_600)
        let first = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(kinds(first.map(\.id)), ["unreadable/actions"])
        let second = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertTrue(second.isEmpty, "told once")
        let events = try await SentinelOne.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        let text = ((try JSONSerialization.jsonObject(with: events) as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Off: network disconnects and threat mitigations a person issued cannot be read"), text)
    }

    /// The note that wakes an agent carries counts and times only: no ID, name, computer or text SentinelOne gave.
    func testWakesCarryOnlyCountsTimesAndHashedIDs() async throws {
        let connection = console()
        let service = S1Log()
        let start = Date().addingTimeInterval(-600)
        service.threats = [S1Log.threat(31_337_000_111, at: start.addingTimeInterval(60))]
        service.activities = [S1Log.activity(31_337_000_222, at: start.addingTimeInterval(120), type: 1001)]
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start))
        let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: SentinelOne.adapter.alertLookBack))
        let found = try await SentinelOne.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.allSatisfy { $0.id.range(of: #"^(threat|activity)/[0-9a-f]{64}$"#, options: .regularExpression) != nil }, "\(found.map(\.id))")
        let news = try XCTUnwrap(watch.take(found, for: connection.id, lookBack: SentinelOne.adapter.alertLookBack))
        let note = AlertWatch.note(news, account: connection.name, skill: "sentinelone", tool: SentinelOne.adapter.watchedTool!)
        for leaked in ["31337", "secret", "victim", "Mimikatz", "ignore-previous", "5550001"] { XCTAssertFalse(note.contains(leaked), note) }
        XCTAssertTrue(note.contains(#"new="2""#) && note.contains(#"tool="security-events""#), note)
    }

    private func poll(_ connection: ToolConnection, _ service: S1Log, from start: Date, most: Int = 20,
                      before: (Int) -> Void = { _ in }) async throws -> (delivered: [String], notices: [String], polls: Int) {
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start.addingTimeInterval(-60)))
        var delivered: [String] = [], notices: [String] = [], polls = 0
        while polls < most {
            polls += 1
            before(polls)
            let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: SentinelOne.adapter.alertLookBack))
            let found: [ServiceAlert]
            do { found = try await SentinelOne.$pause.withValue({ _ in }) { try await SentinelOne.adapter.alerts(since: since, connection: connection, access: service) } } catch { continue }
            XCTAssertLessThanOrEqual(found.count, ServiceAlert.most)
            notices += found.map(\.id).filter { $0.hasPrefix("unchecked/") || $0.hasPrefix("unreadable/") }
            delivered += found.map(\.id).filter { $0.hasPrefix("threat/") }
            let idle = SentinelOne.NewSecurityEvents.kept.withLock { $0[connection.id].map { $0.continuations.isEmpty && $0.owedFrom.isEmpty } ?? true }
            guard watch.take(found, for: connection.id, lookBack: SentinelOne.adapter.alertLookBack) != nil || !idle else { break }
        }
        return (delivered, notices, polls)
    }

    private func kinds(_ notices: [String]) -> [String] { notices.map { $0.split(separator: "/").dropLast().joined(separator: "/") }.sorted() }

    /// A burst bigger than one check returns, and more than one check may read, is all delivered over later checks,
    /// each once, with one notice that more follow.
    func testABurstBiggerThanOneCheckIsAllDeliveredEachOnce() async throws {
        let connection = console()
        let service = S1Log()
        service.pageSize = 100
        let start = Date().addingTimeInterval(-2 * 3_600)
        let ids = (0..<1_500).map { 100_000 + $0 }
        service.threats = ids.enumerated().map { S1Log.threat($1, at: start.addingTimeInterval(Double($0))) }
        let (delivered, notices, _) = try await poll(connection, service, from: start)
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map(threatID)), "every one, the oldest included")
        XCTAssertEqual(kinds(notices), ["unchecked/backlog"], "that more follow is told once")
        let kept = SentinelOne.NewSecurityEvents.kept.withLock { $0[connection.id] }
        XCTAssertTrue(kept?.owedFrom.isEmpty == true && kept?.continuations.isEmpty == true, "nothing owed at the end")
    }

    /// A check that fails for a reason that passes keeps nothing but how many in a row failed, so the next reads the
    /// same window again and returns what it would have.
    func testAFailedCheckKeepsOnlyItsFailureStreakAndRecovers() async throws {
        let connection = console()
        let trigger = SentinelOne.NewSecurityEvents()
        let service = S1Log()
        let first = Date().addingTimeInterval(-10 * 3_600), later = Date()
        service.threats = [S1Log.threat(1, at: first.addingTimeInterval(-60))]
        let found = try await trigger.alerts(since: first.addingTimeInterval(-3_600), on: client(connection, service), account: connection.id, now: first)
        XCTAssertEqual(found.count, 1)
        let before = try XCTUnwrap(SentinelOne.NewSecurityEvents.kept.withLock { $0[connection.id] })
        XCTAssertEqual(before.readUntil["threats"], first)
        service.threats.append(S1Log.threat(2, at: first.addingTimeInterval(3_600)))
        service.mode = .busy
        do {
            _ = try await SentinelOne.$pause.withValue({ _ in }) {
                try await trigger.alerts(since: first.addingTimeInterval(-60), on: client(connection, service), account: connection.id, now: later)
            }
            XCTFail("a passing failure holds the watch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rate limit"), error.localizedDescription)
        }
        let held = try XCTUnwrap(SentinelOne.NewSecurityEvents.kept.withLock { $0[connection.id] })
        XCTAssertEqual(held.inARow.values.max(), 1)
        XCTAssertEqual(held.readUntil, before.readUntil)
        XCTAssertEqual(held.delivered, before.delivered)
        XCTAssertTrue(held.owedFrom.isEmpty && held.continuations.isEmpty && held.told.isEmpty)
        service.mode = .whole
        service.requests = []
        let recovered = try await trigger.alerts(since: first.addingTimeInterval(-20 * 3_600), on: client(connection, service), account: connection.id, now: later)
        XCTAssertEqual(recovered.map(\.id), [threatID(2)], "the earlier one is not news again")
        let read = try XCTUnwrap(service.requests.first { $0.url?.path == "/web/api/v2.1/threats" })
        XCTAssertEqual(queryItems(read)["createdAt__gte"], Entra.iso(first.addingTimeInterval(-6 * 3_600)))
        XCTAssertTrue(SentinelOne.NewSecurityEvents.kept.withLock { $0[connection.id]?.inARow.isEmpty } == true)
    }

    /// A feed that cannot be read wakes the agents once while it stays so, and after holding back a few checks for one
    /// that might pass; reading again ends it, and a new failure wakes again.
    func testAnUnreadableFeedWakesOnceAndAgainOnlyAfterRecovering() async throws {
        let connection = console()
        let trigger = SentinelOne.NewSecurityEvents()
        let service = S1Log()
        let since = Date().addingTimeInterval(-3_600)
        service.mode = .denied
        let told = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(kinds(told.map(\.id)), ["unreadable/actions", "unreadable/disconnected", "unreadable/threats"])
        XCTAssertTrue(told.allSatisfy { $0.time == since }, "dated at the window's start, so it moves nothing on")
        do { _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id); XCTFail("told once") } catch {}
        service.mode = .whole
        _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        service.mode = .busy
        try await SentinelOne.$pause.withValue({ _ in }) {
            for _ in 1...SentinelOne.NewSecurityEvents.holdChecks {
                do { _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id); XCTFail("held back") } catch {}
            }
            let again = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
            XCTAssertEqual(kinds(again.map(\.id)), ["unreadable/actions", "unreadable/disconnected", "unreadable/threats"], "a failure that lasts is told, once more")
        }
        let data = try await SentinelOne.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: { service.mode = .denied; return service }())
        let text = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Nothing could be read") && text.contains("Threats: View"), text)
    }

    /// What one check had no room for, and what it could not read, stays owed through a check that cannot read the
    /// feed, or reads it only in part, however far newer threats moved the watch on, and is handed over, each once,
    /// when the feed reads again.
    func testOverflowADeniedOrTruncatedPollAndRecoveryStillDeliverEverythingOnce() async throws {
        for failure in [S1Log.Mode.denied, .unfollowable, .busy] {
            let connection = console()
            let service = S1Log()
            let start = Date().addingTimeInterval(-12 * 3_600)
            service.pageSize = 150
            let ids = (0..<900).map { 200_000 + $0 }
            service.threats = ids.enumerated().map { index, id in
                S1Log.threat(id, at: start.addingTimeInterval(index < 700 ? Double(index) : Double(index - 699) * 120))
            }
            let (delivered, notices, _) = try await poll(connection, service, from: start) { poll in service.mode = poll == 2 ? failure : .whole }
            XCTAssertEqual(delivered.count, ids.count, "\(failure): each once")
            XCTAssertEqual(Set(delivered), Set(ids.map(threatID)), "\(failure): the oldest too")
            if failure == .denied { XCTAssertTrue(notices.contains { $0.hasPrefix("unreadable/threats/") }, "\(failure): \(notices)") }
            if failure == .unfollowable { XCTAssertTrue(notices.contains { $0.hasPrefix("unchecked/threats/") }, "\(failure): \(notices)") }
            let kept = SentinelOne.NewSecurityEvents.kept.withLock { $0[connection.id] }
            XCTAssertTrue(kept?.owedFrom.isEmpty == true && kept?.continuations.isEmpty == true, "\(failure): nothing owed at the end")
        }
    }

    /// More threats detected at one moment than a check's page budget, and one after them: the watch goes on with the
    /// query it kept and its cursor, never restarting at that moment, so each is delivered exactly once.
    func testMoreTiedThreatsThanThePageBudgetAreEachDeliveredOnce() async throws {
        let connection = console()
        let service = S1Log()
        service.pageSize = 100
        let start = Date().addingTimeInterval(-3 * 3_600), moment = start.addingTimeInterval(60)
        let tied = (0..<(SentinelOne.watchPages * 100 + 150)).map { 300_000 + $0 }
        service.threats = tied.map { S1Log.threat($0, at: moment) } + [S1Log.threat(399_999, at: moment.addingTimeInterval(1))]
        let (delivered, notices, polls) = try await poll(connection, service, from: start)
        XCTAssertLessThan(polls, 20, "it stops finding news")
        XCTAssertEqual(delivered.count, tied.count + 1, "each once")
        XCTAssertEqual(Set(delivered), Set((tied + [399_999]).map(threatID)))
        XCTAssertEqual(kinds(notices), ["unchecked/backlog"], "that more follow is told once")
        let reads = service.requests.filter { $0.url?.path == "/web/api/v2.1/threats" }.map(queryItems)
        let resumed = try XCTUnwrap(reads.dropFirst(SentinelOne.watchPages).first)
        XCTAssertNotNil(resumed["cursor"])
        XCTAssertEqual(resumed["createdAt__gte"], reads.first?["createdAt__gte"], "the same bounded query")
        XCTAssertEqual(resumed["createdAt__lte"], reads.first?["createdAt__lte"], "the same bounded query")
    }

    /// A search that ends after a long continuation, while the watch moved on, leaves a boundary, so a threat detected
    /// just after its end, read by no check yet, is still delivered.
    func testASearchThatEndsAfterALongContinuationLeavesABoundary() async throws {
        let connection = console()
        let trigger = SentinelOne.NewSecurityEvents()
        let service = S1Log()
        let client = client(connection, service)
        let first = Date().addingTimeInterval(-20 * 3_600)
        service.pageSize = 30
        service.threats = (0..<(SentinelOne.watchPages * 30 * 3 + 20)).map { S1Log.threat(400_000 + $0, at: first.addingTimeInterval(-600 + Double($0) / 2)) }
        var caught = try await trigger.alerts(since: first.addingTimeInterval(-3_600), on: client, account: connection.id, now: first).map(\.id)
        let search = try XCTUnwrap(SentinelOne.NewSecurityEvents.kept.withLock { $0[connection.id]?.continuations["threats"] })
        XCTAssertEqual(search.until, first)
        service.threats.append(S1Log.threat(499_999, at: first.addingTimeInterval(30)))
        var later = first
        for _ in 1...3 {
            later = later.addingTimeInterval(4 * 3_600)
            caught += try await trigger.alerts(since: later.addingTimeInterval(-600), on: client, account: connection.id, now: later).map(\.id)
        }
        XCTAssertFalse(caught.contains(threatID(499_999)), "the search reads only its own window")
        XCTAssertEqual(SentinelOne.NewSecurityEvents.kept.withLock { $0[connection.id]?.catchUp["threats"] }, first.addingTimeInterval(-6 * 3_600))
        for check in 1...4 {
            caught += try await trigger.alerts(since: later.addingTimeInterval(-600), on: client, account: connection.id, now: later.addingTimeInterval(Double(check) * 300)).map(\.id)
        }
        XCTAssertEqual(caught.filter { $0 == threatID(499_999) }.count, 1, "\(caught.count)")
        XCTAssertEqual(caught.filter { $0.hasPrefix("threat/") }.count, service.threats.count, "each once")
    }

    /// A cursor SentinelOne turns down is given up, said once, and its window read again from its start, so everything
    /// is still delivered, each once.
    func testARejectedCursorIsGivenUpAndItsWindowReadAgain() async throws {
        let connection = console()
        let service = S1Log()
        let start = Date().addingTimeInterval(-2 * 3_600)
        service.pageSize = 100
        let ids = (0..<900).map { 500_000 + $0 }
        service.threats = ids.enumerated().map { S1Log.threat($1, at: start.addingTimeInterval(Double($0))) }
        let (delivered, notices, _) = try await poll(connection, service, from: start) { poll in service.mode = poll == 2 ? .rejectCursor : .whole }
        XCTAssertTrue(notices.contains { $0.hasPrefix("unchecked/threats/") }, "\(notices)")
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map(threatID)))
        XCTAssertTrue(SentinelOne.NewSecurityEvents.kept.withLock { $0[connection.id]?.owedFrom.isEmpty } == true)
    }

    /// Disconnected agents: the first whole read only learns them; an agent disconnected later is returned once, and
    /// again only after it was reconnected and disconnected again.
    func testAgentsNewlyDisconnectedAreReturnedOnceAfterTheFirstRead() async throws {
        let connection = console()
        let trigger = SentinelOne.NewSecurityEvents()
        let service = S1Log()
        let since = Date().addingTimeInterval(-3_600)
        service.disconnected = ["1111222233334444555"]
        let first = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertTrue(first.isEmpty, "what is disconnected when the watch starts is not news")
        service.disconnected = ["1111222233334444555", "6666777788889999000"]
        let second = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second[0].id.hasPrefix("disconnected/") && !second[0].id.contains("6666777788889999000"), second[0].id)
        let third = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertTrue(third.isEmpty, "told once")
        service.disconnected = ["1111222233334444555"]
        _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        service.disconnected = ["1111222233334444555", "6666777788889999000"]
        let again = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id, now: Date().addingTimeInterval(1))
        XCTAssertEqual(again.count, 1, "disconnected again after a reconnect is news again")
    }

    /// security-events reads the same, says what it searched and when it was cut short, the agents disconnected now,
    /// and what it does not watch.
    func testSecurityEventsSaysWhatItSearchedAndWhatItDidNotRead() async throws {
        let connection = console()
        let service = S1Log()
        let now = Date()
        service.pageSize = 100
        service.threats = (0..<1_050).map { S1Log.threat(600_000 + $0, at: now.addingTimeInterval(-3_000 + Double($0))) }
        service.activities = [S1Log.activity(77, at: now.addingTimeInterval(-600), type: 2002)]
        service.disconnected = ["8888"]
        let data = try await SentinelOne.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? ""
        XCTAssertTrue(text.contains("Malicious threat: Mimikatz") && text.contains("Threat mitigation:") && text.contains("by admin@secret.example"), text)
        XCTAssertTrue(text.contains("Searched: unresolved malicious and suspicious threats") && text.contains("Searched: network disconnects"), text)
        XCTAssertTrue(text.contains("Cut short, with more not read: unresolved malicious and suspicious threats"), text)
        XCTAssertTrue(text.contains("Disconnected from the network or with a disconnect pending now, 1 agent: 8888"), text)
        XCTAssertTrue(text.contains("Not watched:") && text.contains("STAR custom-rule alerts"), text)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["complete"] as? Bool, false)
        XCTAssertEqual(service.requests.filter { $0.url?.path == "/web/api/v2.1/threats" }.count, SentinelOne.eventsPages)
        let refused = try await callTool(SentinelOne.adapter, "security-events", #"{"since":"2020-01-01T00:00:00Z"}"#, on: FakeService(), in: connection)
        XCTAssertTrue(refused.isError, "at most 30 days")
    }
}
