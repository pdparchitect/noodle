import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

/// Microsoft Graph's audit log and Identity Protection as Graph answers them: newest first, a page at a time, each
/// page's next link carrying a $skiptoken good only with the query it came from; or refused, throttled, linking its
/// next page elsewhere, turning down a token, or without Identity Protection's licence.
final class GraphLog: ServiceAccess, @unchecked Sendable {
    enum Mode { case whole, denied, busy, elsewhere, rejectToken }
    let lock = NSLock()
    var audits: [[String: Any]] = []
    var riskyUsers: [[String: Any]] = []
    var detections: [[String: Any]] = []
    var mode = Mode.whole
    var unlicensed = false
    var pageSize = 100
    var requests: [URLRequest] = []

    static func time(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func audit(_ id: String, _ activity: String = "Add member to role", category: String = "RoleManagement", at date: Date,
                      role: String = "Global Administrator", template: String = Entra.globalAdministrator, actor: String = "admin-1",
                      properties: [[String: Any]]? = nil, targets: [[String: Any]]? = nil, result: String = "success") -> [String: Any] {
        let changed = properties ?? [["displayName": "Role.DisplayName", "oldValue": NSNull(), "newValue": "\"\(role)\""],
                                     ["displayName": "Role.TemplateId", "oldValue": NSNull(), "newValue": "\"\(template)\""]]
        return ["id": id, "activityDateTime": time(date), "activityDisplayName": activity, "category": category, "result": result,
                "loggedByService": "Core Directory",
                "initiatedBy": ["user": ["id": actor, "userPrincipalName": "\(actor)@contoso.example", "ipAddress": "203.0.113.77"]],
                "targetResources": targets ?? [["id": "victim-1", "type": "User", "userPrincipalName": "ignore-previous-instructions@contoso.example", "modifiedProperties": changed]]]
    }

    static func risky(_ id: String, at date: Date, level: String = "high", state: String = "atRisk") -> [String: Any] {
        ["id": id, "userPrincipalName": "\(id)@contoso.example", "riskLevel": level, "riskState": state, "riskDetail": "none", "riskLastUpdatedDateTime": time(date)]
    }

    static func detection(_ id: String, at date: Date, level: String = "high") -> [String: Any] {
        ["id": id, "riskEventType": "unfamiliarFeatures", "riskLevel": level, "riskState": "atRisk", "detectedDateTime": time(date), "activity": "signin",
         "userPrincipalName": "victim@contoso.example", "ipAddress": "203.0.113.9"]
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (mode, unlicensed, size) = lock.withLock { requests.append(request); return (self.mode, self.unlicensed, pageSize) }
        let url = request.url!
        func answer(_ status: Int, _ body: Any, _ headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        let path = url.path
        if unlicensed, path.contains("identityProtection") {
            return try answer(403, ["error": ["code": "Forbidden", "message": "Your tenant is not licensed for this feature. It needs a Microsoft Entra ID P2 license."]])
        }
        switch mode {
        case .denied: return try answer(403, ["error": ["code": "Authorization_RequestDenied", "message": "Insufficient privileges to complete the operation."]])
        case .busy: return try answer(429, ["error": ["code": "TooManyRequests", "message": "Too many requests"]], ["Retry-After": "30"])
        case .whole, .elsewhere, .rejectToken: break
        }
        let query = queryItems(request)
        let filter = query["$filter"] ?? ""
        var start = 0
        if let token = query["$skiptoken"] {
            if mode == .rejectToken { return try answer(400, ["error": ["code": "BadRequest", "message": "The $skiptoken has expired."]]) }
            let parts = String(decoding: Data(base64Encoded: token) ?? Data(), as: UTF8.self).split(separator: "|", maxSplits: 1).map(String.init)
            // A token is good only with the query it came from.
            guard parts.count == 2, parts[1] == filter else {
                XCTFail("a $skiptoken sent with another query: \(filter)")
                return try answer(400, ["error": ["code": "BadRequest", "message": "mismatched token"]])
            }
            start = Int(parts[0]) ?? 0
        }
        let times = (try? NSRegularExpression(pattern: #"(ge|le) (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)"#))?.matches(in: filter, range: NSRange(filter.startIndex..., in: filter))
            .reduce(into: [String: Date]()) { found, match in
                found[String(filter[Range(match.range(at: 1), in: filter)!])] = ServiceAlert.time(String(filter[Range(match.range(at: 2), in: filter)!]))
            } ?? [:]
        let (since, until) = (times["ge"] ?? .distantPast, times["le"] ?? .distantFuture)
        let (all, field): ([[String: Any]], String) = lock.withLock {
            if path.hasSuffix("directoryAudits") { return (audits, "activityDateTime") }
            if path.hasSuffix("riskyUsers") { return (riskyUsers, "riskLastUpdatedDateTime") }
            return (detections, "detectedDateTime")
        }
        XCTAssertTrue(filter.contains("ge "), "always bounded below: \(filter)")
        // Newest first, as Graph lists them.
        let matching = all.filter { item in
            guard let time = ServiceAlert.time(item[field] as? String) else { return false }
            return time >= since && time <= until && (field == "activityDateTime" || item["riskLevel"] as? String == "high")
        }.sorted { ($0[field] as! String, $0["id"] as! String) > ($1[field] as! String, $1["id"] as! String) }
        let page = Array(matching.dropFirst(start).prefix(size))
        var body: [String: Any] = ["value": page]
        if start + page.count < matching.count {
            let token = Data("\(start + page.count)|\(filter)".utf8).base64EncodedString()
            var next = URLComponents(string: "https://\(mode == .elsewhere ? "evil.example" : "graph.microsoft.com")\(path)")!
            next.queryItems = [URLQueryItem(name: "$top", value: query["$top"]), URLQueryItem(name: "$skiptoken", value: token)]
            body["@odata.nextLink"] = next.string!
        }
        return try answer(200, body)
    }
}

final class EntraWatchTests: XCTestCase {
    private func tenant() -> ToolConnection {
        try! Entra.preset.makeConnection(name: "Entra — Contoso", values: ["tenant": "contoso.onmicrosoft.com", "clientID": EntraTests.client])
    }

    private func client(_ connection: ToolConnection, _ access: any ServiceAccess) -> ServiceClient {
        ServiceClient(base: connection.endpoint, access: access, settings: connection.settings ?? [:], account: connection.id)
    }

    private func judged(_ audit: [String: Any]) throws -> (tier: Int, kind: String, what: String)? {
        Entra.judge(try JSONDecoder().decode(Entra.Audit.self, from: JSONSerialization.data(withJSONObject: audit)))
    }

    /// The watch wakes for what hands over the tenant, opens a way back in or weakens its defences, and not for what is
    /// routine, failed or only asked for.
    func testTheWatchJudgesHighRiskChangesAndLeavesTheRest() throws {
        let now = Date()
        func property(_ name: String, _ old: String?, _ new: String?) -> [String: Any] { ["displayName": name, "oldValue": old ?? NSNull(), "newValue": new ?? NSNull()] }
        XCTAssertEqual(try judged(GraphLog.audit("1", at: now))?.kind, "privileged role granted")
        XCTAssertEqual(try judged(GraphLog.audit("1", at: now))?.tier, 0)
        XCTAssertNil(try judged(GraphLog.audit("2", at: now, role: "Helpdesk Administrator", template: "729827e3-9c14-49f7-bb1b-9608f156bbb8")))
        XCTAssertNil(try judged(GraphLog.audit("3", at: now, result: "failure")))
        let roleTarget: [[String: Any]] = [["id": "194ae4cb-b126-40b2-bd5b-6091b380977d", "type": "Role", "displayName": "Security Administrator"],
                                           ["id": "u9", "type": "User", "userPrincipalName": "bo@contoso.example"]]
        XCTAssertEqual(try judged(GraphLog.audit("4", "Add member to role completed (PIM activation)", at: now, properties: [], targets: roleTarget))?.kind,
                       "privileged role activated")
        XCTAssertNil(try judged(GraphLog.audit("5", "Add member to role requested (PIM activation)", at: now, properties: [], targets: roleTarget)))
        XCTAssertEqual(try judged(GraphLog.audit("6", "Add eligible member to role in PIM completed (permanent)", at: now, properties: [], targets: roleTarget))?.kind,
                       "privileged role made eligible")
        let app: [String: Any] = ["id": "app-1", "type": "Application", "displayName": "Payroll Sync"]
        func appChange(_ id: String, _ activity: String, _ properties: [[String: Any]]) throws -> (tier: Int, kind: String, what: String)? {
            var target = app
            target["modifiedProperties"] = properties
            return try judged(GraphLog.audit(id, activity, category: "ApplicationManagement", at: now, targets: [target]))
        }
        let added = try appChange("7", "Update application – Certificates and secrets management ", [property("KeyDescription", "[]", "[\"[KeyIdentifier=k1,KeyType=Password]\"]")])
        XCTAssertEqual(added?.kind, "app credential added")
        XCTAssertTrue(added?.what.contains("added to app Payroll Sync") == true, added?.what ?? "")
        XCTAssertNil(try appChange("8", "Update application – Certificates and secrets management ", [property("KeyDescription", "[\"[KeyIdentifier=k1]\"]", "[]")]),
                     "a credential removed is no way in")
        XCTAssertEqual(try appChange("9", "Consent to application", [property("ConsentContext.IsAdminConsent", nil, "\"True\""),
                                                                      property("ConsentAction.Permissions", nil, "\"[] => [[Scope: User.Read]]\"")])?.kind, "admin consent to an app")
        XCTAssertEqual(try appChange("10", "Consent to application", [property("ConsentContext.IsAdminConsent", nil, "\"False\""),
                                                                       property("ConsentAction.Permissions", nil, "\"Scope: Mail.Read User.Read\"")])?.kind, "consent to high privileges")
        XCTAssertEqual(try appChange("11", "Consent to application", [property("ConsentContext.IsAdminConsent", nil, "\"False\""),
                                                                       property("ConsentAction.Permissions", nil, "\"Scope: User.Read openid\"")])?.tier, 2)
        XCTAssertEqual(try appChange("12", "Add app role assignment to service principal", [property("AppRole.Value", nil, "\"RoleManagement.ReadWrite.Directory\"")])?.tier, 0)
        XCTAssertEqual(try judged(GraphLog.audit("13", "Set federation settings on domain", category: "DirectoryManagement", at: now,
                                                 targets: [["id": "d1", "type": "Domain", "displayName": "contoso.com"]]))?.kind, "federation changed")
        let policy: [[String: Any]] = [["id": "p1", "type": "Policy", "displayName": "Require MFA for admins"]]
        XCTAssertEqual(try judged(GraphLog.audit("14", "Delete conditional access policy", category: "Policy", at: now, targets: policy))?.tier, 0)
        XCTAssertEqual(try judged(GraphLog.audit("15", "Update conditional access policy", category: "Policy", at: now, targets: policy))?.kind, "Conditional Access policy changed")
        XCTAssertEqual(try judged(GraphLog.audit("16", "Admin registered security info", category: "UserManagement", at: now, properties: []))?.kind,
                       "sign-in method changed by an admin")
        XCTAssertNil(try judged(GraphLog.audit("17", "User registered security info", category: "UserManagement", at: now, properties: [])))
        XCTAssertEqual(try judged(GraphLog.audit("18", "Update user", category: "UserManagement", at: now,
                                                 properties: [property("StrongAuthenticationMethod", "[]", "[{\"MethodType\":6}]")]))?.kind, "sign-in method changed by someone else")
        XCTAssertNil(try judged(GraphLog.audit("19", "Update user", category: "UserManagement", at: now, actor: "victim-1",
                                               properties: [property("StrongAuthenticationMethod", "[]", "[{\"MethodType\":6}]")])), "a user changing their own")
        XCTAssertNil(try judged(GraphLog.audit("20", "Update user", category: "UserManagement", at: now, properties: [property("DisplayName", "\"A\"", "\"B\"")])))
    }

    /// The note that wakes an agent carries counts and times only: no ID, name, address or text Graph gave.
    func testWakesCarryOnlyCountsTimesAndHashedIDs() async throws {
        let connection = tenant()
        let service = GraphLog()
        let start = Date().addingTimeInterval(-600)
        service.audits = [GraphLog.audit("audit-secret-1", at: start.addingTimeInterval(60))]
        service.riskyUsers = [GraphLog.risky("risky-secret-1", at: start.addingTimeInterval(120))]
        service.detections = [GraphLog.detection("detection-secret-1", at: start.addingTimeInterval(180)), GraphLog.detection("low-1", at: start.addingTimeInterval(180), level: "low")]
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start))
        let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: Entra.adapter.alertLookBack))
        let found = try await Entra.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(Set(found.map(\.id)), [Entra.safeID("audit/", "audit-secret-1"), Entra.safeID("detection/", "detection-secret-1"),
                                              Entra.safeID("riskyuser/", "risky-secret-1|\(GraphLog.time(start.addingTimeInterval(120)))")])
        XCTAssertTrue(found.allSatisfy { $0.id.range(of: #"^(audit|riskyuser|detection)/[0-9a-f]{64}$"#, options: .regularExpression) != nil })
        let news = try XCTUnwrap(watch.take(found, for: connection.id, lookBack: Entra.adapter.alertLookBack))
        let note = AlertWatch.note(news, account: connection.name, skill: "entra", tool: Entra.adapter.watchedTool!)
        for leaked in ["secret", "admin-1", "203.0.113", "ignore-previous", "victim"] { XCTAssertFalse(note.contains(leaked), note) }
        XCTAssertTrue(note.contains(#"new="3""#), note)
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "graph.microsoft.com" })
    }

    /// Polls through the real AlertWatch until one returns nothing new with nothing left owed or to read on, at most
    /// `most`, saying what each delivered and the notices. A check reading on through what was returned before finds
    /// nothing new, but the watch checks again five minutes later all the same.
    private func poll(_ connection: ToolConnection, _ service: GraphLog, from start: Date, most: Int = 20,
                      before: (Int) -> Void = { _ in }) async throws -> (delivered: [String], notices: [String], polls: Int) {
        var watch = AlertWatch()
        XCTAssertNil(watch.since(connection.id, at: start.addingTimeInterval(-60)))
        var delivered: [String] = [], notices: [String] = [], polls = 0
        while polls < most {
            polls += 1
            before(polls)
            let since = try XCTUnwrap(watch.since(connection.id, at: Date(), lookBack: Entra.adapter.alertLookBack))
            let found: [ServiceAlert]
            do { found = try await Entra.adapter.alerts(since: since, connection: connection, access: service) } catch { continue }
            XCTAssertLessThanOrEqual(found.count, ServiceAlert.most)
            notices += found.map(\.id).filter { $0.hasPrefix("unchecked/") || $0.hasPrefix("unreadable/") }
            delivered += found.map(\.id).filter { $0.hasPrefix("audit/") }
            let idle = Entra.NewSecurityEvents.kept.withLock { $0[connection.id].map { $0.continuations.isEmpty && $0.owedFrom.isEmpty } ?? true }
            guard watch.take(found, for: connection.id, lookBack: Entra.adapter.alertLookBack) != nil || !idle else { break }
        }
        return (delivered, notices, polls)
    }

    private func kinds(_ notices: [String]) -> [String] { notices.map { $0.split(separator: "/").dropLast().joined(separator: "/") } }

    /// A burst bigger than one check returns, and more than one check may read, is all delivered over later checks,
    /// each once, with one notice that more follow.
    func testABurstBiggerThanOneCheckIsAllDeliveredEachOnce() async throws {
        let connection = tenant()
        let service = GraphLog()
        service.pageSize = 200
        let start = Date().addingTimeInterval(-2 * 3_600)
        let ids = (0..<1_500).map { String(format: "burst-%05d", $0) }
        service.audits = ids.enumerated().map { index, id in
            index % 2 == 0 ? GraphLog.audit(id, at: start.addingTimeInterval(Double(index)))
                : GraphLog.audit(id, "Admin registered security info", category: "UserManagement", at: start.addingTimeInterval(Double(index)), properties: [])
        }
        let (delivered, notices, _) = try await poll(connection, service, from: start)
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map { Entra.safeID("audit/", $0) }), "every one, the oldest included")
        XCTAssertEqual(kinds(notices), ["unchecked/backlog"], "that more follow is told once")
        let kept = Entra.NewSecurityEvents.kept.withLock { $0[connection.id] }
        XCTAssertTrue(kept?.owedFrom.isEmpty == true && kept?.continuations.isEmpty == true, "nothing owed at the end")
    }

    /// A check that fails for a reason that passes keeps nothing but how many in a row failed, so the next reads the
    /// same window again and returns what it would have.
    func testAFailedCheckKeepsOnlyItsFailureStreakAndRecovers() async throws {
        let connection = tenant()
        let trigger = Entra.NewSecurityEvents()
        let service = GraphLog()
        let first = Date().addingTimeInterval(-10 * 3_600), later = Date()
        service.audits = [GraphLog.audit("before", at: first.addingTimeInterval(-60))]
        let found = try await trigger.alerts(since: first.addingTimeInterval(-3_600), on: client(connection, service), account: connection.id, now: first)
        XCTAssertEqual(found.count, 1)
        let before = try XCTUnwrap(Entra.NewSecurityEvents.kept.withLock { $0[connection.id] })
        XCTAssertEqual(before.readUntil["directory-audit"], first)
        service.audits.append(GraphLog.audit("during", at: first.addingTimeInterval(3_600)))
        service.mode = .busy
        do {
            _ = try await trigger.alerts(since: first.addingTimeInterval(-60), on: client(connection, service), account: connection.id, now: later)
            XCTFail("a passing failure holds the watch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("asked to wait 30 seconds"), error.localizedDescription)
        }
        let held = try XCTUnwrap(Entra.NewSecurityEvents.kept.withLock { $0[connection.id] })
        XCTAssertEqual(held.inARow.values.max(), 1)
        XCTAssertEqual(held.readUntil, before.readUntil)
        XCTAssertEqual(held.delivered, before.delivered)
        XCTAssertTrue(held.owedFrom.isEmpty && held.continuations.isEmpty && held.told.isEmpty)
        service.mode = .whole
        service.requests = []
        // However far back the watch would read, it reads from six hours before the last whole read, for late entries.
        let recovered = try await trigger.alerts(since: first.addingTimeInterval(-20 * 3_600), on: client(connection, service), account: connection.id, now: later)
        XCTAssertEqual(recovered.map(\.id), [Entra.safeID("audit/", "during")], "the earlier one is not news again")
        let audit = try XCTUnwrap(service.requests.first { $0.url?.path.hasSuffix("directoryAudits") == true })
        XCTAssertTrue(queryItems(audit)["$filter"]?.hasPrefix("activityDateTime ge \(Entra.iso(first.addingTimeInterval(-6 * 3_600)))") == true, queryItems(audit)["$filter"] ?? "")
        XCTAssertTrue(Entra.NewSecurityEvents.kept.withLock { $0[connection.id]?.inARow.isEmpty } == true)
    }

    /// A feed that cannot be read wakes the agents once while it stays so, and after holding back a few checks for one
    /// that might pass; reading again ends it, and a new failure wakes again.
    func testAnUnreadableFeedWakesOnceAndAgainOnlyAfterRecovering() async throws {
        let connection = tenant()
        let trigger = Entra.NewSecurityEvents()
        let service = GraphLog()
        let since = Date().addingTimeInterval(-3_600)
        service.mode = .denied
        let told = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(Set(kinds(told.map(\.id))), ["unreadable/directory-audit", "unreadable/risky-users", "unreadable/risk-detections"])
        XCTAssertTrue(told.allSatisfy { $0.time == since }, "dated at the window's start, so it moves nothing on")
        do { _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id); XCTFail("told once") } catch {}
        service.mode = .whole
        _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        service.mode = .busy
        for _ in 1...Entra.NewSecurityEvents.holdChecks {
            do { _ = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id); XCTFail("held back") } catch {}
        }
        let again = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(Set(kinds(again.map(\.id))), ["unreadable/directory-audit", "unreadable/risky-users", "unreadable/risk-detections"],
                       "a failure that lasts is told, once more")
    }

    /// Identity Protection without its licence is said once as off, and the audit log is still watched.
    func testAFeedWithoutItsLicenceIsSaidOnceAndTheRestIsWatched() async throws {
        let connection = tenant()
        let trigger = Entra.NewSecurityEvents()
        let service = GraphLog()
        service.unlicensed = true
        let since = Date().addingTimeInterval(-3_600)
        service.audits = [GraphLog.audit("granted", at: since.addingTimeInterval(60))]
        let first = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertEqual(Set(first.map(\.id)), Set([Entra.safeID("audit/", "granted")] + first.filter { $0.id.hasPrefix("unreadable/") }.map(\.id)))
        XCTAssertEqual(Set(kinds(first.filter { $0.id.hasPrefix("unreadable/") }.map(\.id))), ["unreadable/risky-users", "unreadable/risk-detections"])
        let second = try await trigger.alerts(since: since, on: client(connection, service), account: connection.id)
        XCTAssertTrue(second.isEmpty, "told once: \(second)")
        let read = try await callTool(Entra.adapter, "security-events", "{}", on: FakeService(), in: connection)
        XCTAssertTrue(read.isError, "the stand-in for every other request knows no log")
        let data = try await Entra.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        let text = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Off: Identity Protection's risky users cannot be read without Microsoft Entra ID P2"), text)
        XCTAssertTrue(text.contains("privileged role granted") || text.contains("Global Administrator granted"), text)
    }

    /// What one check had no room for, and what it could not read, stays owed through a check that cannot read the log,
    /// or reads it only in part, however far newer entries moved the watch on, and is handed over, each once, when the
    /// log reads again.
    func testOverflowADeniedOrTruncatedPollAndRecoveryStillDeliverEverythingOnce() async throws {
        for failure in [GraphLog.Mode.denied, .elsewhere, .busy] {
            let connection = tenant()
            let service = GraphLog()
            // More than a check returns, read on over more than one check, so the second reads on from a token.
            service.pageSize = 150
            let start = Date().addingTimeInterval(-12 * 3_600)
            let ids = (0..<900).map { String(format: "owed-%05d", $0) }
            // A burst at the start, then one a minute, spread wider than the six hours the watch reads back.
            service.audits = ids.enumerated().map { index, id in
                let time = start.addingTimeInterval(index < 700 ? Double(index) : Double(index - 699) * 120)
                return index % 3 == 0 ? GraphLog.audit(id, at: time) : GraphLog.audit(id, "Admin deleted security info", category: "UserManagement", at: time, properties: [])
            }
            let (delivered, notices, _) = try await poll(connection, service, from: start) { poll in service.mode = poll == 2 ? failure : .whole }
            XCTAssertEqual(delivered.count, ids.count, "\(failure): each once")
            XCTAssertEqual(Set(delivered), Set(ids.map { Entra.safeID("audit/", $0) }), "\(failure): the oldest too")
            if failure == .denied { XCTAssertTrue(notices.contains { $0.hasPrefix("unreadable/directory-audit/") }, "\(failure): \(notices)") }
            if failure == .elsewhere { XCTAssertTrue(notices.contains { $0.hasPrefix("unchecked/directory-audit/") }, "\(failure): \(notices)") }
            let kept = Entra.NewSecurityEvents.kept.withLock { $0[connection.id] }
            XCTAssertTrue(kept?.owedFrom.isEmpty == true && kept?.continuations.isEmpty == true, "\(failure): nothing owed at the end")
        }
    }

    /// More entries made at one moment than a check's page budget, and one after them: the watch goes on with Graph's
    /// $skiptoken and the query it came from, never restarting at that moment, so each is delivered exactly once and it
    /// does not read the same pages for ever.
    func testMoreTiedEntriesThanThePageBudgetAreEachDeliveredOnce() async throws {
        let connection = tenant()
        let service = GraphLog()
        let start = Date().addingTimeInterval(-3 * 3_600), moment = start.addingTimeInterval(60)
        let tied = (0..<(Entra.watchPages * service.pageSize + 150)).map { String(format: "tied-%05d", $0) }
        service.audits = tied.map { GraphLog.audit($0, at: moment) } + [GraphLog.audit("after-the-tie", at: moment.addingTimeInterval(1))]
        let (delivered, notices, polls) = try await poll(connection, service, from: start)
        XCTAssertLessThan(polls, 20, "it stops finding news")
        XCTAssertEqual(delivered.count, tied.count + 1, "each once")
        XCTAssertEqual(Set(delivered), Set((tied + ["after-the-tie"]).map { Entra.safeID("audit/", $0) }))
        XCTAssertEqual(kinds(notices), ["unchecked/backlog"], "that more follow is told once")
        // The second check went on with the first's token and query, not from the tied moment.
        let audits = service.requests.filter { $0.url?.path.hasSuffix("directoryAudits") == true }
        let resumed = try XCTUnwrap(audits.dropFirst(Entra.watchPages).first)
        XCTAssertNotNil(queryItems(resumed)["$skiptoken"])
        XCTAssertEqual(queryItems(resumed)["$filter"], queryItems(audits.first)["$filter"], "the same bounded query")
    }

    /// A query that ends after a long continuation, while the watch moved on, leaves a boundary, so an entry made just
    /// after its end, read by no check yet, is still delivered.
    func testAQueryThatEndsAfterALongContinuationLeavesABoundary() async throws {
        let connection = tenant()
        let trigger = Entra.NewSecurityEvents()
        let service = GraphLog()
        let client = client(connection, service)
        let first = Date().addingTimeInterval(-20 * 3_600)
        // Small pages, so the query takes several checks, each with room to return all it read.
        service.pageSize = 30
        service.audits = (0..<(Entra.watchPages * service.pageSize * 3 + 20)).map { GraphLog.audit(String(format: "q-%05d", $0), at: first.addingTimeInterval(-600 + Double($0) / 2)) }
        var caught = try await trigger.alerts(since: first.addingTimeInterval(-3_600), on: client, account: connection.id, now: first).map(\.id)
        let query = try XCTUnwrap(Entra.NewSecurityEvents.kept.withLock { $0[connection.id]?.continuations["directory-audit"] })
        XCTAssertEqual(query.until, first)
        // Made just after the query's end, and found by none of its pages.
        service.audits.append(GraphLog.audit("just-after", at: first.addingTimeInterval(30)))
        var later = first
        // The watch moves on well past it while the query is read on.
        for _ in 1...3 {
            later = later.addingTimeInterval(4 * 3_600)
            caught += try await trigger.alerts(since: later.addingTimeInterval(-600), on: client, account: connection.id, now: later).map(\.id)
        }
        XCTAssertFalse(caught.contains(Entra.safeID("audit/", "just-after")), "the query reads only its own window")
        XCTAssertEqual(Entra.NewSecurityEvents.kept.withLock { $0[connection.id]?.catchUp["directory-audit"] }, first.addingTimeInterval(-6 * 3_600))
        // Read from the boundary, not from where the watch is.
        for check in 1...4 {
            caught += try await trigger.alerts(since: later.addingTimeInterval(-600), on: client, account: connection.id, now: later.addingTimeInterval(Double(check) * 300)).map(\.id)
        }
        XCTAssertEqual(caught.filter { $0 == Entra.safeID("audit/", "just-after") }.count, 1, "\(caught.count)")
        XCTAssertEqual(caught.filter { $0.hasPrefix("audit/") }.count, service.audits.count, "each once")
    }

    /// A $skiptoken Graph turns down is given up, said once, and its window read again from its start, so everything is
    /// still delivered, each once.
    func testARejectedTokenIsGivenUpAndItsWindowReadAgain() async throws {
        let connection = tenant()
        let service = GraphLog()
        let start = Date().addingTimeInterval(-2 * 3_600)
        let ids = (0..<900).map { String(format: "rt-%05d", $0) }
        service.audits = ids.enumerated().map { GraphLog.audit($1, at: start.addingTimeInterval(Double($0))) }
        let (delivered, notices, _) = try await poll(connection, service, from: start) { poll in service.mode = poll == 2 ? .rejectToken : .whole }
        XCTAssertTrue(notices.contains { $0.hasPrefix("unchecked/directory-audit/") }, "\(notices)")
        XCTAssertEqual(delivered.count, ids.count, "each once")
        XCTAssertEqual(Set(delivered), Set(ids.map { Entra.safeID("audit/", $0) }))
        XCTAssertTrue(Entra.NewSecurityEvents.kept.withLock { $0[connection.id]?.owedFrom.isEmpty } == true)
    }

    /// security-events reads the same, says what it searched and when it was cut short, and what it does not watch.
    func testSecurityEventsSaysWhatItSearchedAndWhatItDidNotRead() async throws {
        let connection = tenant()
        let service = GraphLog()
        let now = Date()
        service.audits = (0..<1_050).map { GraphLog.audit(String(format: "se-%05d", $0), at: now.addingTimeInterval(-3_000 + Double($0))) }
        service.riskyUsers = [GraphLog.risky("r1", at: now.addingTimeInterval(-600))]
        let data = try await Entra.adapter.run("security-events", arguments: Data("{}".utf8), connection: connection, access: service)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? ""
        XCTAssertTrue(text.contains("Global Administrator granted") && text.contains("rates r1@contoso.example at high risk"), text)
        XCTAssertTrue(text.contains("Searched: the directory audit log") && text.contains("Searched: Identity Protection's risk detections"), text)
        XCTAssertTrue(text.contains("Cut short, with more not read: the directory audit log"), text)
        XCTAssertTrue(text.contains("Not watched:"), text)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["complete"] as? Bool, false)
        XCTAssertEqual(service.requests.filter { $0.url?.path.hasSuffix("directoryAudits") == true }.count, Entra.eventsPages)
    }
}
