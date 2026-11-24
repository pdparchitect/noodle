import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class SentinelOneContainmentTests: XCTestCase {
    private let s1 = try! SentinelOne.containment.makeConnection(name: "SentinelOne Containment — Kestrel", values: ["console": "usea1-kestrel.sentinelone.net"])
    private let api = "/web/api/v2.1"
    private let agentID = "1234567890123456789", threatID = "9876543210987654321", siteID = "111", entryID = "7001"
    private let sha1 = String(repeating: "ab", count: 20)

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await SentinelOne.$pauses.withValue([0]) {
            try await SentinelOne.$pause.withValue({ _ in }) { try await callTool(SentinelOne.containmentAdapter, tool, arguments, on: service, in: s1) }
        }
    }

    private func client(_ service: FakeService) -> ServiceClient { ServiceClient(base: s1.endpoint, access: service, account: s1.id) }

    /// The changes a call sent: every request but a read.
    private func changes(_ service: FakeService) -> [String] {
        service.requests.filter { $0.httpMethod != "GET" }.map { "\($0.httpMethod!) \($0.url!.path)" }
    }

    private func body(_ request: URLRequest?) -> [String: Any] {
        request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func sent(_ service: FakeService, _ path: String) -> URLRequest? { service.requests.last { $0.httpMethod != "GET" && $0.url?.path == api + path } }

    private func agent(network: String? = "connected", active: Bool = true, extra: String = "") -> (Int, String) {
        let status = network.map { #","networkStatus":"\#($0)""# } ?? ""
        return (200, #"{"data":[{"id":"\#(agentID)","computerName":"LT-0423","osType":"windows","isActive":\#(active)\#(status)\#(extra)}],"pagination":{"totalItems":1}}"#)
    }

    private func threat(os: String? = "windows", mitigations: String? = "[]", status: String = "unresolved", verdict: String = "undefined", id: String? = nil) -> String {
        let osField = os.map { #","agentOsType":"\#($0)""# } ?? ""
        let history = mitigations.map { #","mitigationStatus":\#($0)"# } ?? ""
        return #"{"id":"\#(id ?? threatID)","threatInfo":{"threatName":"evil.exe","incidentStatus":"\#(status)","analystVerdict":"\#(verdict)","createdAt":"2026-11-23T08:00:00Z"},"agentRealtimeInfo":{"agentId":"\#(agentID)","agentComputerName":"LT-0423"\#(osField)}\#(history)}"#
    }

    private func threats(_ items: String...) -> (Int, String) { (200, #"{"data":[\#(items.joined(separator: ","))],"pagination":{"totalItems":\#(items.count)}}"#) }
    private func affected(_ count: Int?) -> (Int, String) { (200, count.map { #"{"data":{"affected":\#($0)}}"# } ?? #"{"data":{}}"#) }

    func testContainmentIsItsOwnToolWithAServiceUserAndRoleOfItsOwn() throws {
        XCTAssertEqual(SentinelOne.containment.name, "SentinelOne Containment")
        XCTAssertNotEqual(SentinelOne.containment.id, SentinelOne.preset.id)
        XCTAssertNotNil(UUID(uuidString: SentinelOne.containment.id))
        XCTAssertEqual(s1.endpoint.absoluteString, "https://usea1-kestrel.sentinelone.net/web/api/v2.1")
        XCTAssertEqual(s1.tokenScheme, "ApiToken")
        XCTAssertEqual(s1.adapter, "sentinelone-containment")
        XCTAssertNotNil(PionAdapters.all["sentinelone-containment"])
        XCTAssertNil(SentinelOne.containmentAdapter.watchedTool)
        XCTAssertTrue(PionCatalogue.entries.contains { $0.id == SentinelOne.containment.id })
        let setup = SentinelOne.containmentSetup.joined(separator: "\n")
        for permission in SentinelOne.containmentPermissions { XCTAssertTrue(setup.contains("**\(permission)**"), permission) }
        XCTAssertTrue(setup.contains("Pion Containment") && setup.contains("apart from Pion Audit's"), setup)
    }

    /// Every change but reopening a threat or setting a verdict short of false positive is held for approval and says
    /// what recovering from it involves; the reads are not held.
    func testEveryActionIsHeldForApprovalAndSaysHowToRecover() async throws {
        let listed = try JSONSerialization.jsonObject(with: try await SentinelOne.containmentAdapter.tools(for: s1)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        func tool(_ name: String) throws -> [String: Any] { try XCTUnwrap(tools.first { $0["name"] as? String == name }, name) }
        let recovery: [String: [String]] = [
            "disconnect-agent": ["reconnect-agent restores", "must be asked for explicitly", "every workload on it is cut off", "filter of that ID alone"],
            "reconnect-agent": ["disconnect-agent again", "an attacker's still on it"],
            "initiate-scan": ["none needed", "CPU and disk", "Abort Scan"],
            "kill-threat": ["memory and unsaved work are gone for good"],
            "quarantine-threat": ["unquarantine-threat restores the file"],
            "unquarantine-threat": ["quarantine-threat again", "can run again"],
            "remediate-threat": ["none through SentinelOne", "registry keys"],
            "rollback-threat": ["Windows only", "Volume Shadow Copy", "undoes any legitimate change", "may undo the user's own changes"],
            "resolve-threat": ["update-threat-status unresolved or in_progress reopens", "false-positive verdict, hides it"],
            "block-hash": ["unblock-hash with the entry's ID removes it", "keep a record that Pion made it", "whoever made it"],
            "unblock-hash": ["block-hash again restores it", "by its ID", "whatever its description says"],
        ]
        for (name, words) in recovery {
            let annotations = try XCTUnwrap(try tool(name)["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false, name)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, true, name)
            let summary = try XCTUnwrap(try tool(name)["description"] as? String)
            XCTAssertTrue(summary.contains("Recovery:"), name)
            for word in words { XCTAssertTrue(summary.contains(word), "\(name) says \(word): \(summary)") }
        }
        let update = try XCTUnwrap(try tool("update-threat-status")["annotations"] as? [String: Any])
        XCTAssertEqual(update["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(update["destructiveHint"] as? Bool, false, "reopening hides nothing")
        let verdicts = (((try tool("update-threat-status")["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["verdict"] as? [String: Any])?["enum"] as? [String]
        XCTAssertFalse(verdicts?.contains("false_positive") ?? true, "a false positive hides the threat, so only resolve-threat sets it")
        for name in ["agent", "threat", "action-status", "check-access"] {
            XCTAssertEqual((try tool(name)["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true, name)
        }
    }

    /// A disconnect goes with a filter of the one agent's ID and nothing else, after reading it through that filter;
    /// pending is said to be pending, and done only once the status follows.
    func testDisconnectSendsOnlyTheExactIDAndSaysPendingIsNotDone() async throws {
        for (after, done) in [("disconnecting", false), ("disconnected", true)] {
            let service = FakeService()
            service.sequences["\(api)/agents"] = [agent(), agent(network: after)]
            service.answers["\(api)/agents/actions/disconnect"] = affected(1)
            let result = try await call("disconnect-agent", #"{"id":"\#(agentID)"}"#, service)
            XCTAssertFalse(result.isError, result.text)
            XCTAssertEqual(changes(service), ["POST \(api)/agents/actions/disconnect"])
            let sent = body(sent(service, "/agents/actions/disconnect"))
            XCTAssertEqual(sent["filter"] as? [String: [String]], ["ids": [agentID]], "the exact ID alone")
            XCTAssertEqual((sent["data"] as? [String: Any])?.isEmpty, true)
            XCTAssertEqual(Set(sent.keys), ["filter", "data"])
            XCTAssertEqual(queryItems(service.requests.first)["ids"], agentID, "read through the same filter first")
            XCTAssertEqual(result.structured?["done"] as? Bool, done)
            XCTAssertEqual(result.text.contains("Pending is not done"), !done, result.text)
            XCTAssertTrue(result.text.contains("Recovery: reconnect-agent"), result.text)
        }
    }

    func testDisconnectRefusesWhatItCannotReadWholeOrWhatIsAlreadySo() async throws {
        let cases: [(String, (Int, String), String)] = [
            ("disconnected", agent(network: "disconnected"), "already disconnected"),
            ("disconnecting", agent(network: "disconnecting"), "already pending"),
            ("connecting", agent(network: "connecting"), "would race"),
            ("absent", (200, #"{"data":[],"pagination":{"totalItems":0}}"#), "has no agent"),
            ("errors", (200, #"{"data":[],"errors":[{"code":4000010}]}"#), "could not be read whole"),
            ("another", (200, #"{"data":[{"id":"555","computerName":"X"}]}"#), "could not be read whole"),
            ("more match", (200, #"{"data":[{"id":"\#(agentID)"}],"pagination":{"totalItems":3}}"#), "could not be read whole"),
            ("unreadable", (200, #"{"data":[{"computerName":"no id"}]}"#), "Nothing was changed"),
        ]
        for (label, answer, said) in cases {
            let service = FakeService()
            service.answers["\(api)/agents"] = answer
            service.answers["\(api)/agents/actions/disconnect"] = affected(1)
            let result = try await call("disconnect-agent", #"{"id":"\#(agentID)"}"#, service)
            XCTAssertTrue(result.isError && result.text.contains(said), "\(label): \(result.text)")
            XCTAssertTrue(changes(service).isEmpty, label)
        }
        let malformed = FakeService()
        for id in ["12,13", "abc", "", "1 OR 1"] {
            let result = try await call("disconnect-agent", #"{"id":"\#(id)"}"#, malformed)
            XCTAssertTrue(result.isError, id)
        }
        XCTAssertTrue(malformed.requests.isEmpty)
    }

    /// An unknown prior state never blocks, and is said; a count other than the one agent, or a state that does not
    /// follow, is unverified, with the request's details.
    func testUnknownStateIsSaidAndAWrongCountOrStateIsUnverified() async throws {
        let unknown = FakeService()
        unknown.sequences["\(api)/agents"] = [agent(network: nil), agent(network: "disconnected")]
        unknown.answers["\(api)/agents/actions/disconnect"] = affected(1)
        let said = try await call("disconnect-agent", #"{"id":"\#(agentID)"}"#, unknown)
        XCTAssertTrue(!said.isError && said.text.contains("could not be confirmed"), said.text)
        XCTAssertTrue(said.text.contains("not that this request, rather than an earlier one, brought it about"), "an unknown baseline confirms the state, not its cause: \(said.text)")
        for (count, words) in [(0, "affected none"), (2, "⚠ SentinelOne said it affected 2, more than the 1 approved"), (nil, "did not say how many")] as [(Int?, String)] {
            let service = FakeService()
            service.answers["\(api)/agents"] = agent()
            service.answers["\(api)/agents/actions/disconnect"] = affected(count)
            let result = try await call("disconnect-agent", #"{"id":"\#(agentID)"}"#, service)
            XCTAssertTrue(result.isError && result.text.contains(words) && result.text.contains("not reported done"), "\(String(describing: count)): \(result.text)")
            XCTAssertTrue(result.text.contains("Request: POST /web/api/v2.1/agents/actions/disconnect with filter ids [\(agentID)]"), result.text)
        }
        let stuck = FakeService()
        stuck.answers["\(api)/agents"] = agent()
        stuck.answers["\(api)/agents/actions/disconnect"] = affected(1)
        let result = try await call("disconnect-agent", #"{"id":"\#(agentID)"}"#, stuck)
        XCTAssertTrue(result.isError && result.text.contains("could not be verified") && result.text.contains("connected (not disconnected"), result.text)
    }

    func testReconnectAndScan() async throws {
        let connected = FakeService()
        connected.answers["\(api)/agents"] = agent()
        let nothing = try await call("reconnect-agent", #"{"id":"\#(agentID)"}"#, connected)
        XCTAssertTrue(nothing.isError && nothing.text.contains("nothing to reconnect") && changes(connected).isEmpty, nothing.text)
        let service = FakeService()
        service.sequences["\(api)/agents"] = [agent(network: "disconnected"), agent(network: "connected")]
        service.answers["\(api)/agents/actions/connect"] = affected(1)
        let back = try await call("reconnect-agent", #"{"id":"\#(agentID)"}"#, service)
        XCTAssertTrue(!back.isError && back.structured?["done"] as? Bool == true, back.text)
        XCTAssertEqual(body(sent(service, "/agents/actions/connect"))["filter"] as? [String: [String]], ["ids": [agentID]])

        let scanning = FakeService()
        scanning.answers["\(api)/agents"] = agent(extra: #","scanStatus":"started","scanStartedAt":"2026-11-23T09:00:00Z""#)
        let busy = try await call("initiate-scan", #"{"id":"\#(agentID)"}"#, scanning)
        XCTAssertTrue(busy.isError && busy.text.contains("already scanning") && changes(scanning).isEmpty, busy.text)
        let started = FakeService()
        started.sequences["\(api)/agents"] = [agent(extra: #","scanStatus":"finished""#), agent(extra: #","scanStatus":"started","scanStartedAt":"\#(Entra.iso(Date()))""#)]
        started.answers["\(api)/agents/actions/initiate-scan"] = affected(1)
        let scan = try await call("initiate-scan", #"{"id":"\#(agentID)"}"#, started)
        XCTAssertTrue(!scan.isError && scan.structured?["started"] as? Bool == true && scan.text.contains("Abort Scan"), scan.text)
        let queued = FakeService()
        queued.answers["\(api)/agents"] = agent(active: false, extra: #","scanStatus":"finished""#)
        queued.answers["\(api)/agents/actions/initiate-scan"] = affected(1)
        let later = try await call("initiate-scan", #"{"id":"\#(agentID)"}"#, queued)
        XCTAssertTrue(!later.isError && later.structured?["started"] as? Bool == false && later.text.contains("pending, not done"), later.text)
    }

    /// A mitigation reads the threat whole, goes with its ID alone, and is done only when the threat's history then
    /// shows a new record of that action that succeeded; pending is pending, failed fails, and no record is unverified.
    func testAMitigationIsConfirmedOnlyByANewRecordOfThatAction() async throws {
        let kill = #"{"action":"kill","status":"success","mitigationEndedAt":"2026-11-23T08:01:00Z"}"#
        for (record, done, error, words) in [(#"{"action":"quarantine","status":"success","mitigationEndedAt":"2026-11-23T09:00:00Z"}"#, true, false, "quarantine success"),
                                             (#"{"action":"quarantine","status":"pending"}"#, false, false, "Pending is not done"),
                                             (#"{"action":"quarantine","status":"failed"}"#, false, true, "now says it failed"),
                                             (nil, false, true, "shows no new record")] as [(String?, Bool, Bool, String)] {
            let service = FakeService()
            service.sequences["\(api)/threats"] = [threats(threat(mitigations: "[\(kill)]")), threats(threat(mitigations: "[\([kill, record].compactMap { $0 }.joined(separator: ","))]"))]
            service.answers["\(api)/threats/mitigate/quarantine"] = affected(1)
            let result = try await call("quarantine-threat", #"{"id":"\#(threatID)"}"#, service)
            XCTAssertEqual(result.isError, error, result.text)
            XCTAssertTrue(result.text.contains(words), "\(words): \(result.text)")
            if !error { XCTAssertEqual(result.structured?["done"] as? Bool, done) }
            XCTAssertEqual(changes(service), ["POST \(api)/threats/mitigate/quarantine"])
            XCTAssertEqual(body(sent(service, "/threats/mitigate/quarantine"))["filter"] as? [String: [String]], ["ids": [threatID]])
            XCTAssertEqual(queryItems(service.requests.first)["ids"], threatID)
        }
    }

    func testAMitigationRefusesWhatIsAlreadySoOrPendingAndRollbackOffWindows() async throws {
        let quarantined = #"{"action":"quarantine","status":"success","mitigationEndedAt":"2026-11-23T09:00:00Z"}"#
        let released = #"{"action":"un-quarantine","status":"success","mitigationEndedAt":"2026-11-23T10:00:00Z"}"#
        let cases: [(String, String, String)] = [
            ("quarantine-threat", threat(mitigations: "[\(quarantined)]"), "already through quarantine"),
            ("quarantine-threat", threat(mitigations: #"[{"action":"quarantine","status":"pending"}]"#), "already pending"),
            ("unquarantine-threat", threat(mitigations: "[]"), "is not quarantined"),
            ("unquarantine-threat", threat(mitigations: "[\(quarantined),\(released)]"), "is not quarantined"),
            ("remediate-threat", threat(mitigations: #"[{"action":"remediate","status":"success"}]"#), "already through remediation"),
            ("rollback-threat", threat(os: "linux"), "rollback works only on Windows"),
            ("rollback-threat", threat(os: nil), "Windows could not be confirmed"),
            ("kill-threat", threat(mitigations: #"[{"action":"kill","status":"pending_reboot"}]"#), "already pending"),
        ]
        for (tool, answer, said) in cases {
            let service = FakeService()
            service.answers["\(api)/threats"] = threats(answer)
            let result = try await call(tool, #"{"id":"\#(threatID)"}"#, service)
            XCTAssertTrue(result.isError && result.text.contains(said), "\(tool) \(said): \(result.text)")
            XCTAssertTrue(changes(service).isEmpty, tool)
        }
        // Quarantined again after a release, or a history not given, never blocks; the latter is said.
        for (history, note) in [("[\(released.replacingOccurrences(of: "10:00", with: "08:00")),\(quarantined.replacingOccurrences(of: "09:00", with: "07:00"))]", nil), (nil, "gave no mitigation history")] as [(String?, String?)] {
            let service = FakeService()
            let done = #"{"action":"quarantine","status":"success","mitigationEndedAt":"\#(Entra.iso(Date().addingTimeInterval(60)))"}"#
            service.sequences["\(api)/threats"] = [threats(threat(mitigations: history)), threats(threat(mitigations: "[\(done)]"))]
            service.answers["\(api)/threats/mitigate/quarantine"] = affected(1)
            let result = try await call("quarantine-threat", #"{"id":"\#(threatID)"}"#, service)
            XCTAssertFalse(result.isError, result.text)
            if let note { XCTAssertTrue(result.text.contains(note), result.text) }
        }
        let windows = FakeService()
        windows.sequences["\(api)/threats"] = [threats(threat()), threats(threat(mitigations: #"[{"action":"rollback","status":"success"}]"#))]
        windows.answers["\(api)/threats/mitigate/rollback-remediation"] = affected(1)
        let rolled = try await call("rollback-threat", #"{"id":"\#(threatID)"}"#, windows)
        XCTAssertTrue(!rolled.isError && rolled.text.contains("Volume Shadow Copy"), rolled.text)
    }

    /// Resolving reads every threat through the filter it then uses, refuses those already as asked, and is done only
    /// when each is then as asked.
    func testResolvingAndReopeningThreats() async throws {
        let other = "1111111111111111111"
        let service = FakeService()
        service.sequences["\(api)/threats"] = [threats(threat(), threat(id: other)),
                                              threats(threat(status: "resolved", verdict: "false_positive"), threat(status: "resolved", verdict: "false_positive", id: other))]
        service.answers["\(api)/threats/analyst-verdict"] = affected(2)
        service.answers["\(api)/threats/incident"] = affected(2)
        let result = try await call("resolve-threat", #"{"ids":["\#(threatID)","\#(other)"],"verdict":"false_positive"}"#, service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(changes(service), ["POST \(api)/threats/analyst-verdict", "POST \(api)/threats/incident"])
        XCTAssertEqual(body(sent(service, "/threats/incident"))["filter"] as? [String: [String]], ["ids": [threatID, other]])
        XCTAssertEqual(body(sent(service, "/threats/incident"))["data"] as? [String: String], ["incidentStatus": "resolved"])
        XCTAssertEqual(body(sent(service, "/threats/analyst-verdict"))["data"] as? [String: String], ["analystVerdict": "false_positive"])
        XCTAssertEqual(queryItems(service.requests.first)["ids"], "\(threatID),\(other)")

        let already = FakeService()
        already.answers["\(api)/threats"] = threats(threat(status: "resolved"))
        let refused = try await call("resolve-threat", #"{"ids":["\#(threatID)"]}"#, already)
        XCTAssertTrue(refused.isError && refused.text.contains("already as asked") && changes(already).isEmpty, refused.text)
        let partial = FakeService()
        partial.answers["\(api)/threats"] = threats(threat())
        let missing = try await call("resolve-threat", #"{"ids":["\#(threatID)","\#(other)"]}"#, partial)
        XCTAssertTrue(missing.isError && missing.text.contains("not returned: \(other)") && changes(partial).isEmpty, missing.text)
        let short = FakeService()
        short.answers["\(api)/threats"] = threats(threat())
        short.answers["\(api)/threats/incident"] = affected(0)
        let unverified = try await call("resolve-threat", #"{"ids":["\#(threatID)"]}"#, short)
        XCTAssertTrue(unverified.isError && unverified.text.contains("affected none") && unverified.text.contains("Request: POST"), unverified.text)
        let notFollowed = FakeService()
        notFollowed.answers["\(api)/threats"] = threats(threat())
        notFollowed.answers["\(api)/threats/incident"] = affected(1)
        let stale = try await call("resolve-threat", #"{"ids":["\#(threatID)"]}"#, notFollowed)
        XCTAssertTrue(stale.isError && stale.text.contains("not reported done"), stale.text)

        let reopen = FakeService()
        reopen.sequences["\(api)/threats"] = [threats(threat(status: "resolved")), threats(threat(status: "in_progress"))]
        reopen.answers["\(api)/threats/incident"] = affected(1)
        let reopened = try await call("update-threat-status", #"{"ids":["\#(threatID)"],"status":"in_progress"}"#, reopen)
        XCTAssertFalse(reopened.isError, reopened.text)
        let hiding = try await call("update-threat-status", #"{"ids":["\#(threatID)"],"verdict":"false_positive"}"#, FakeService())
        XCTAssertTrue(hiding.isError, "a false positive is resolve-threat's")
    }

    private func entry(value: String? = nil, updated: String = "2026-11-23T10:00:00Z", os: String = "windows") -> String {
        #"{"id":"\#(entryID)","type":"black_hash","value":"\#(value ?? sha1)","osType":"\#(os)","description":"Pion, after the champion's approval: INV-12","scopeName":"HQ","siteId":"\#(siteID)","updatedAt":"\#(updated)","userId":"42"}"#
    }

    private func site(_ service: FakeService) {
        service.answers["\(api)/sites"] = (200, #"{"data":{"sites":[{"id":"\#(siteID)","name":"HQ"}]},"pagination":{"totalItems":1}}"#)
    }

    private func record(_ service: FakeService) throws {
        let made = try JSONDecoder().decode(SentinelOne.BlockEntry.self, from: Data(entry().utf8))
        try SentinelOne.changeRecords(client(service)) { $0.removeAll { $0.id == self.entryID }; $0.append(SentinelOne.BlockRecord(id: entryID, site: siteID, created: Date(), made: SentinelOne.BlockSnapshot(made), changedSinceCreation: false)) }
    }

    /// A hash is blocked in one site, refused when any entry already holds it, and recorded as read back, so only
    /// unblock-hash can remove it.
    func testBlockingAHashKeepsPionsRecordOnlyOfWhatItMade() async throws {
        let held = FakeService()
        site(held)
        held.answers["\(api)/restrictions"] = (200, #"{"data":[\#(entry())],"pagination":{"totalItems":1}}"#)
        let refused = try await call("block-hash", #"{"hash":"\#(sha1)","osType":"windows","siteId":"\#(siteID)","description":"INV-12 dropper"}"#, held)
        XCTAssertTrue(refused.isError && refused.text.contains("already holds") && refused.text.contains("no record of making") && changes(held).isEmpty, refused.text)
        let existing = queryItems(held.requests.last)
        XCTAssertEqual(existing["siteIds"], siteID)
        XCTAssertEqual(existing["includeParents"], "true")

        let service = FakeService()
        site(service)
        service.sequences["\(api)/restrictions"] = [(200, #"{"data":[],"pagination":{"totalItems":0}}"#), (200, #"{"data":[\#(entry())]}"#), (200, #"{"data":[\#(entry())],"pagination":{"totalItems":1}}"#)]
        let made = try await call("block-hash", #"{"hash":"\#(sha1.uppercased())","osType":"windows","siteId":"\#(siteID)","description":"INV-12 dropper"}"#, service)
        XCTAssertFalse(made.isError, made.text)
        XCTAssertEqual(made.structured?["id"] as? String, entryID)
        let request = body(sent(service, "/restrictions"))
        XCTAssertEqual(request["filter"] as? [String: [String]], ["siteIds": [siteID]])
        XCTAssertEqual((request["data"] as? [String: String])?["value"], sha1)
        XCTAssertEqual((request["data"] as? [String: String])?["type"], "black_hash")
        XCTAssertEqual(try SentinelOne.recorded(entryID, client(service))?.site, siteID)

        let other = FakeService()
        site(other)
        other.sequences["\(api)/restrictions"] = [(200, #"{"data":[],"pagination":{"totalItems":0}}"#), (200, #"{"data":[\#(entry(value: String(repeating: "c", count: 40)))]}"#)]
        let mismatch = try await call("block-hash", #"{"hash":"\#(String(repeating: "d", count: 40))","osType":"windows","siteId":"\#(siteID)","description":"INV-12 dropper"}"#, other)
        XCTAssertTrue(mismatch.isError && mismatch.text.contains("did not name exactly one black_hash entry") && mismatch.text.contains("Pion kept no record"), mismatch.text)
        for hash in ["xyz", String(repeating: "a", count: 32)] {
            let result = try await call("block-hash", #"{"hash":"\#(hash)","osType":"windows","siteId":"\#(siteID)","description":"INV-12"}"#, FakeService())
            XCTAssertTrue(result.isError, hash)
        }
    }

    /// unblock-hash removes only an entry Pion's record holds, by its ID alone, while SentinelOne still gives it as
    /// made, and says removed only once SentinelOne plainly holds none.
    func testUnblockingRemovesOnlyPionsOwnUnchangedEntryByID() async throws {
        let unknown = FakeService()
        let none = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, unknown)
        XCTAssertTrue(none.isError && none.text.contains("no record of making") && unknown.requests.isEmpty, none.text)

        let changed = FakeService()
        try record(changed)
        changed.answers["\(api)/restrictions"] = (200, #"{"data":[\#(entry(updated: "2026-11-23T11:00:00Z", os: "macos"))],"pagination":{"totalItems":1}}"#)
        let refused = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, changed)
        XCTAssertTrue(refused.isError && refused.text.contains("not, or cannot be shown to be, as Pion made it") && refused.text.contains("OS windows is now macos") && changes(changed).isEmpty, refused.text)

        for (label, answer) in [("errors", (200, #"{"data":[],"errors":[{"title":"Server Error"}]}"#)), ("404 without naming it", (404, #"{"errors":[{"title":"Not Found"}]}"#)),
                                ("another entry", (200, #"{"data":[{"id":"9999","value":"x"}]}"#))] {
            let service = FakeService()
            try record(service)
            service.answers["\(api)/restrictions"] = answer
            let result = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, service)
            XCTAssertTrue(result.isError && result.text.contains("could not be told") && changes(service).isEmpty, "\(label): \(result.text)")
            XCTAssertNotNil(try SentinelOne.recorded(entryID, client(service)), label)
        }
        let gone = FakeService()
        try record(gone)
        gone.answers["\(api)/restrictions"] = (200, #"{"data":[],"pagination":{"totalItems":0}}"#)
        let nothing = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, gone)
        XCTAssertTrue(nothing.isError && nothing.text.contains("holds no blocklist entry") && changes(gone).isEmpty, nothing.text)
        XCTAssertNil(try SentinelOne.recorded(entryID, client(gone)))

        let service = FakeService()
        try record(service)
        service.sequences["\(api)/restrictions"] = [(200, #"{"data":[\#(entry())],"pagination":{"totalItems":1}}"#), affected(1), (200, #"{"data":[],"pagination":{"totalItems":0}}"#)]
        let removed = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, service)
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertEqual(changes(service), ["DELETE \(api)/restrictions"])
        let removal = body(sent(service, "/restrictions"))["data"] as? [String: Any]
        XCTAssertEqual(removal?["type"] as? String, "black_hash")
        XCTAssertEqual(removal?["ids"] as? [String], [entryID], "by its ID alone")
        XCTAssertEqual(removal?.count, 2)
        XCTAssertNil(body(sent(service, "/restrictions"))["filter"], "never a filter")
        XCTAssertNil(try SentinelOne.recorded(entryID, client(service)))

        let still = FakeService()
        try record(still)
        let held: (Int, String) = (200, #"{"data":[\#(entry())],"pagination":{"totalItems":1}}"#)
        still.sequences["\(api)/restrictions"] = [held, affected(1), held]
        let kept = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, still)
        XCTAssertTrue(kept.isError && kept.text.contains("still holds") && kept.text.contains("Pion keeps its record"), kept.text)
        XCTAssertNotNil(try SentinelOne.recorded(entryID, client(still)))
    }

    /// With the threat's history not given before, a successful record is this request's only when dated at or after
    /// it: an older one is not taken as done.
    func testAnUnknownHistoryTakesOnlyARecordDatedAfterTheRequest() async throws {
        for (time, done) in [("2026-01-01T00:00:00Z", false), (Entra.iso(Date().addingTimeInterval(120)), true)] {
            let service = FakeService()
            let record = #"{"action":"kill","status":"success","mitigationEndedAt":"\#(time)"}"#
            service.sequences["\(api)/threats"] = [threats(threat(mitigations: nil)), threats(threat(mitigations: "[\(record)]"))]
            service.answers["\(api)/threats/mitigate/kill"] = affected(1)
            let result = try await call("kill-threat", #"{"id":"\#(threatID)"}"#, service)
            if done { XCTAssertTrue(!result.isError && result.structured?["done"] as? Bool == true, result.text) }
            else { XCTAssertTrue(result.isError && result.text.contains("not reported done") && result.text.contains("history before was not given"), result.text) }
        }
        // A record without a time cannot be dated, so it is not taken either.
        let undated = FakeService()
        undated.sequences["\(api)/threats"] = [threats(threat(mitigations: nil)), threats(threat(mitigations: #"[{"action":"kill","status":"success"}]"#))]
        undated.answers["\(api)/threats/mitigate/kill"] = affected(1)
        let result = try await call("kill-threat", #"{"id":"\#(threatID)"}"#, undated)
        XCTAssertTrue(result.isError && result.text.contains("not reported done"), result.text)
    }

    /// Ownership rests only on a plain answer to the request that made the entry: an answer with errors, or that is
    /// ambiguous or names no site, leaves no record; an entry changed before it is first read back is recorded as
    /// changed, which unblock-hash leaves to the console.
    func testOwnershipRestsOnlyOnAPlainCreateAnswer() async throws {
        let empty: (Int, String) = (200, #"{"data":[],"pagination":{"totalItems":0}}"#)
        let arguments = #"{"hash":"\#(sha1)","osType":"windows","siteId":"\#(siteID)","description":"INV-12 dropper"}"#
        let unplain: [(String, (Int, String), String)] = [
            ("errors beside the entry", (200, #"{"data":[\#(entry())],"errors":[{"code":4000010,"title":"Partial"}]}"#), "carried errors"),
            ("an error without a message", (200, #"{"data":[\#(entry())],"errors":[{}]}"#), "carried errors"),
            ("two entries", (200, #"{"data":[\#(entry()),\#(entry())]}"#), "did not name exactly one"),
            ("another type", (200, #"{"data":[\#(entry().replacingOccurrences(of: "black_hash", with: "white_hash"))]}"#), "did not name exactly one"),
            ("no site ID, only the site's name", (200, #"{"data":[\#(entry().replacingOccurrences(of: #","siteId":"\#(siteID)""#, with: ""))]}"#), "gives no site ID"),
            ("another site of the same name", (200, #"{"data":[\#(entry().replacingOccurrences(of: #""siteId":"\#(siteID)""#, with: #""siteId":"202""#))]}"#), "places it in site 202"),
            ("unreadable", (200, "[]"), "could not be read"),
        ]
        for (label, answer, said) in unplain {
            let service = FakeService()
            site(service)
            service.sequences["\(api)/restrictions"] = [empty, answer, (200, #"{"data":[\#(entry())],"pagination":{"totalItems":1}}"#)]
            let result = try await call("block-hash", arguments, service)
            XCTAssertTrue(result.isError && result.text.contains(said) && result.text.contains("Pion kept no record"), "\(label): \(result.text)")
            XCTAssertNil(try SentinelOne.recorded(entryID, client(service)), label)
        }
        let edited = FakeService()
        site(edited)
        edited.sequences["\(api)/restrictions"] = [empty, (200, #"{"data":[\#(entry())]}"#),
                                                   (200, #"{"data":[\#(entry(value: String(repeating: "e", count: 40), updated: "2026-11-23T10:05:00Z"))],"pagination":{"totalItems":1}}"#)]
        let result = try await call("block-hash", arguments, edited)
        XCTAssertTrue(result.isError && result.text.contains("not as SentinelOne said it made it") && result.text.contains("marked changed"), result.text)
        let record = try XCTUnwrap(try SentinelOne.recorded(entryID, client(edited)))
        XCTAssertTrue(record.changedSinceCreation)
        XCTAssertEqual(record.made.value, sha1, "the baseline is what the create answer gave, never the reread")
        edited.answers["\(api)/restrictions"] = (200, #"{"data":[\#(entry(value: String(repeating: "e", count: 40)))],"pagination":{"totalItems":1}}"#)
        let before = edited.requests.count
        let refused = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, edited)
        XCTAssertTrue(refused.isError && refused.text.contains("Remove it in the console"), refused.text)
        XCTAssertTrue(edited.requests.dropFirst(before).isEmpty, "nothing sent for an entry changed since it was made")
    }

    /// A removal is confirmed only by an answer counting exactly the one entry, with no error, before an empty read;
    /// anything else is unverified and the record kept, even when the read then finds none. A read that contradicts
    /// itself keeps the record too.
    func testAnUnblockIsConfirmedOnlyByAPlainCountOfOne() async throws {
        let present: (Int, String) = (200, #"{"data":[\#(entry())],"pagination":{"totalItems":1}}"#)
        let gone: (Int, String) = (200, #"{"data":[],"pagination":{"totalItems":0}}"#)
        for (label, answer, said) in [("none", affected(0), "affected none"), ("no count", affected(nil), "did not say how many"),
                                      ("unreadable", (200, "not json"), "could not be read"), ("errors", (200, #"{"data":{"affected":1},"errors":[{"code":5000}]}"#), "gave errors"),
                                      ("two", affected(2), "more than the 1 approved")] as [(String, (Int, String), String)] {
            let service = FakeService()
            try record(service)
            service.sequences["\(api)/restrictions"] = [present, answer, gone]
            let result = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, service)
            XCTAssertTrue(result.isError && result.text.contains(said) && result.text.contains("not reported removed"), "\(label): \(result.text)")
            XCTAssertNotNil(try SentinelOne.recorded(entryID, client(service)), "\(label): the record is kept")
        }
        for (label, answer) in [("a next page with none counted", (200, #"{"data":[],"pagination":{"nextCursor":"more","totalItems":0}}"#)),
                                ("none counted beside the entry", (200, #"{"data":[\#(entry())],"pagination":{"totalItems":0}}"#)),
                                ("an empty page with a next page", (200, #"{"data":[],"pagination":{"nextCursor":"more"}}"#)),
                                ("a route 404 echoing the ID", (404, #"{"errors":[{"code":404,"detail":"route not found /restrictions?ids=\#(entryID)"}]}"#))] {
            let before = FakeService()
            try record(before)
            before.answers["\(api)/restrictions"] = answer
            let refused = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, before)
            XCTAssertTrue(refused.isError && refused.text.contains("could not be told") && changes(before).isEmpty, "\(label): \(refused.text)")
            XCTAssertNotNil(try SentinelOne.recorded(entryID, client(before)), label)
            let after = FakeService()
            try record(after)
            after.sequences["\(api)/restrictions"] = [present, affected(1), answer]
            let unverified = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, after)
            XCTAssertTrue(unverified.isError && unverified.text.contains("unverified"), "\(label) after: \(unverified.text)")
            XCTAssertNotNil(try SentinelOne.recorded(entryID, client(after)), "\(label) after: the record is kept")
        }
    }

    /// The site is the site ID SentinelOne gives, never the name: an entry read back, or read before removal, with the
    /// right ID but another site ID, or none, is not Pion's to remove.
    func testTheSiteIsBoundByItsIDOnTheFirstReadAndBeforeRemoval() async throws {
        let moved = entry().replacingOccurrences(of: #""siteId":"\#(siteID)""#, with: #""siteId":"202""#)
        let unsited = entry().replacingOccurrences(of: #","siteId":"\#(siteID)""#, with: "")
        for (label, reread) in [("another site ID", moved), ("no site ID", unsited)] {
            let service = FakeService()
            site(service)
            service.sequences["\(api)/restrictions"] = [(200, #"{"data":[],"pagination":{"totalItems":0}}"#), (200, #"{"data":[\#(entry())]}"#),
                                                        (200, #"{"data":[\#(reread)],"pagination":{"totalItems":1}}"#)]
            let made = try await call("block-hash", #"{"hash":"\#(sha1)","osType":"windows","siteId":"\#(siteID)","description":"INV-12 dropper"}"#, service)
            XCTAssertTrue(made.isError && made.text.contains("site ID") && made.text.contains("marked changed"), "\(label): \(made.text)")
            XCTAssertEqual(try SentinelOne.recorded(entryID, client(service))?.changedSinceCreation, true, label)

            let removal = FakeService()
            try record(removal)
            removal.answers["\(api)/restrictions"] = (200, #"{"data":[\#(reread)],"pagination":{"totalItems":1}}"#)
            let refused = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, removal)
            XCTAssertTrue(refused.isError && refused.text.contains("site ID") && changes(removal).isEmpty, "\(label): \(refused.text)")
            XCTAssertNotNil(try SentinelOne.recorded(entryID, client(removal)), label)
        }
    }

    /// A count or cursor of the wrong type makes an answer unreadable, never one without them, and a count that differs
    /// from what was given is inconclusive: before the removal nothing is sent, after it nothing is reported removed,
    /// and the record is kept either way.
    func testMalformedOrMismatchedPagingIsInconclusive() async throws {
        let present: (Int, String) = (200, #"{"data":[\#(entry())],"pagination":{"totalItems":1}}"#)
        for (label, answer) in [("a count as text", (200, #"{"data":[],"pagination":{"totalItems":"1"}}"#)),
                                ("a count as text beside the entry", (200, #"{"data":[\#(entry())],"pagination":{"totalItems":"1"}}"#)),
                                ("a cursor as a number", (200, #"{"data":[],"pagination":{"nextCursor":5}}"#)),
                                ("a count of one with nothing given", (200, #"{"data":[],"pagination":{"totalItems":1}}"#))] {
            let before = FakeService()
            try record(before)
            before.answers["\(api)/restrictions"] = answer
            let refused = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, before)
            XCTAssertTrue(refused.isError && refused.text.contains("could not be told") && changes(before).isEmpty, "\(label): \(refused.text)")
            XCTAssertNotNil(try SentinelOne.recorded(entryID, client(before)), label)
            let after = FakeService()
            try record(after)
            after.sequences["\(api)/restrictions"] = [present, affected(1), answer]
            let unverified = try await call("unblock-hash", #"{"id":"\#(entryID)"}"#, after)
            XCTAssertTrue(unverified.isError && unverified.text.contains("unverified"), "\(label) after: \(unverified.text)")
            XCTAssertNotNil(try SentinelOne.recorded(entryID, client(after)), "\(label) after")
        }
    }

    /// The record outlasts a relaunch in the file the app names, and is kept per connection.
    func testTheRecordOutlastsARelaunchAndIsKeptPerConnection() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sentinelone-blocklist.json")
        defer {
            SentinelOne.keepBlocklistRecords(at: nil)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        SentinelOne.keepBlocklistRecords(at: file)
        let service = FakeService()
        try record(service)
        SentinelOne.keepBlocklistRecords(at: file)
        XCTAssertEqual(try SentinelOne.recorded(entryID, client(service))?.made.value, sha1, "read back from the file")
        let other = try SentinelOne.containment.makeConnection(name: "Another", values: ["console": "usea1-kestrel.sentinelone.net"])
        XCTAssertNil(try SentinelOne.recorded(entryID, ServiceClient(base: other.endpoint, access: service, account: other.id)), "another connection's record is its own")
        XCTAssertThrowsError(try SentinelOne.recorded(entryID, ServiceClient(base: s1.endpoint, access: service)), "no connection, no record")
    }

    func testActionStatusAndCheckAccessOnlyRead() async throws {
        let service = FakeService()
        service.answers["\(api)/agents"] = agent(network: "disconnecting")
        service.answers["\(api)/activities"] = (200, #"{"data":[{"id":"77","activityType":1001,"primaryDescription":"Pion Containment disconnected LT-0423","createdAt":"2026-11-23T10:00:00Z","userId":"42"}],"pagination":{}}"#)
        let status = try await call("action-status", #"{"agentId":"\#(agentID)"}"#, service)
        XCTAssertTrue(status.text.contains("not settled") && status.text.contains("Pion Containment disconnected"), status.text)
        service.answers["\(api)/user"] = (200, #"{"data":{"id":"42","fullName":"Pion Containment","scope":"site","scopeRoles":[{"roleName":"Admin","name":"HQ"}]}}"#)
        for path in ["threats", "restrictions"] { service.answers["\(api)/\(path)"] = (200, #"{"data":[],"pagination":{"totalItems":0}}"#) }
        site(service)
        let access = try await call("check-access", "{}", service)
        XCTAssertTrue(access.text.contains("⚠ It holds admin") && access.text.contains("Not verified: Endpoints: Disconnect From Network"), access.text)
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" })
        service.answers["\(api)/user"] = (200, #"{"data":{"id":"42","scopeRoles":[{"roleName":"Viewer"}]}}"#)
        let viewer = try await call("check-access", "{}", service)
        XCTAssertTrue(viewer.text.contains("✗ It holds only Viewer"), viewer.text)
        let bad = try SentinelOne.containment.makeConnection(name: "Bad", values: ["console": "evil.example"])
        let elsewhere = FakeService()
        let refused = try await SentinelOne.$pause.withValue({ _ in }) { try await callTool(SentinelOne.containmentAdapter, "disconnect-agent", #"{"id":"\#(agentID)"}"#, on: elsewhere, in: bad) }
        XCTAssertTrue(refused.isError && elsewhere.requests.isEmpty, refused.text)
    }
}
