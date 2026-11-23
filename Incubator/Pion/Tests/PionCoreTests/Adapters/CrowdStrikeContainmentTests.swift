import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class CrowdStrikeContainmentTests: XCTestCase {
    private let falcon = try! CrowdStrike.containment.makeConnection(name: "Falcon Containment — Kestrel", values: ["region": "api.us-2.crowdstrike.com"])
    private let laptop = "0123456789abcdef0123456789abcdef", other = "fedcba9876543210fedcba9876543210"
    private let sha256 = String(repeating: "ab", count: 32)

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await CrowdStrike.$pauses.withValue([0]) {
            try await CrowdStrike.$pause.withValue({ _ in }) { try await callTool(CrowdStrike.containmentAdapter, tool, arguments, on: service, in: falcon) }
        }
    }

    /// The changes a call sent: every request but a read.
    private func changes(_ service: FakeService) -> [String] {
        service.requests.filter { $0.httpMethod != "GET" && !["/devices/entities/devices/v2", "/alerts/entities/alerts/v2"].contains($0.url!.path) }
            .map { "\($0.httpMethod!) \($0.url!.path)" }
    }

    private func body(_ request: URLRequest?) -> [String: Any] {
        request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func host(_ id: String, status: String = "normal", extra: String = "") -> (Int, String) {
        (200, #"{"resources":[{"device_id":"\#(id)","hostname":"LT-0423","platform_name":"Windows","os_version":"Windows 11","status":"\#(status)","last_seen":"2026-11-23T09:00:00Z"\#(extra)}],"errors":[]}"#)
    }

    /// A customer with an online laptop in the given containment status.
    private func customer(status: String = "normal", online: String = "online", extra: String = "") -> FakeService {
        let service = FakeService()
        service.answers["/devices/entities/devices/v2"] = host(laptop, status: status, extra: extra)
        service.answers["/devices/entities/online-state/v1"] = (200, #"{"resources":[{"id":"\#(laptop)","state":"\#(online)"}]}"#)
        return service
    }

    func testContainmentIsItsOwnToolWithAnAPIClientAndScopesOfItsOwn() throws {
        XCTAssertEqual(CrowdStrike.containment.name, "CrowdStrike Falcon Containment")
        XCTAssertNotEqual(CrowdStrike.containment.id, CrowdStrike.preset.id)
        XCTAssertNotNil(UUID(uuidString: CrowdStrike.containment.id))
        XCTAssertEqual(falcon.endpoint.absoluteString, "https://api.us-2.crowdstrike.com")
        XCTAssertEqual(falcon.clientCredentials?.tokenEndpoint.absoluteString, "https://api.us-2.crowdstrike.com/oauth2/token")
        XCTAssertEqual(falcon.adapter, "crowdstrike-containment")
        XCTAssertNotNil(PionAdapters.all["crowdstrike-containment"])
        XCTAssertNil(CrowdStrike.containmentAdapter.watchedTool)
        XCTAssertTrue(PionCatalogue.entries.contains { $0.id == CrowdStrike.containment.id })
        XCTAssertThrowsError(try CrowdStrike.containment.makeConnection(name: "Bad", values: ["region": "evil.example"]))
        let setup = CrowdStrike.containmentSetup.joined(separator: "\n")
        for scope in CrowdStrike.containmentScopes { XCTAssertTrue(setup.contains(scope.shown), scope.plain) }
        XCTAssertTrue(setup.contains("Never give it **Real time response (admin): Write**"))
        XCTAssertFalse(CrowdStrike.containmentScopes.contains { $0.name.contains("admin") || $0.name == "Host groups" })
        XCTAssertTrue(Set(CrowdStrike.auditScopes).isDisjoint(with: CrowdStrike.containmentScopes.filter { $0.access == "Write" }), "Audit holds no write scope")
    }

    /// Every change but setting an alert in progress or reopening it is held for approval and says what recovering
    /// from it involves; the reads are not held.
    func testEveryActionIsHeldForApprovalAndSaysHowToRecover() async throws {
        let listed = try JSONSerialization.jsonObject(with: try await CrowdStrike.containmentAdapter.tools(for: falcon)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        func tool(_ name: String) throws -> [String: Any] { try XCTUnwrap(tools.first { $0["name"] as? String == name }, name) }
        let recovery: [String: [String]] = [
            "contain-host": ["lift-containment restores the host's network access", "must be asked for explicitly", "every pod and container it runs included", "kubernetes-suggested",
                             "suggests but does not verify"],
            "lift-containment": ["contain-host again", "an attacker's still on it"],
            "block-ioc": ["unblock-ioc with the indicator's ID removes it", "does not restore a file it quarantined", "detect only", "keep a record that Pion made it"],
            "unblock-ioc": ["block-ioc again restores it", "on every host at once", "by its ID", "whatever its source or description says"],
            "rtr-kill-process": ["memory and unsaved work are gone for good", "not proof that the kill ended it"],
            "close-alert": ["update-alert-status reopened puts each back", "hides them"],
        ]
        for (name, words) in recovery {
            let annotations = try XCTUnwrap(try tool(name)["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false, name)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, true, name)
            let summary = try XCTUnwrap(try tool(name)["description"] as? String)
            XCTAssertTrue(summary.contains("Recovery:"), name)
            for word in words { XCTAssertTrue(summary.contains(word), "\(name) says \(word): \(summary)") }
        }
        let status = try XCTUnwrap(try tool("update-alert-status")["annotations"] as? [String: Any])
        XCTAssertEqual(status["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(status["destructiveHint"] as? Bool, false, "reopening or setting in progress hides nothing, so it is not held")
        for name in ["host", "action-status", "check-access"] {
            XCTAssertEqual((try tool(name)["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true, name)
        }
        XCTAssertEqual(tools.count, recovery.count + 4)
        XCTAssertFalse(tools.contains { ["script", "run-command", "delete", "quarantine"].contains(where: ($0["name"] as? String ?? "").contains) },
                       "no free-form command, script, deletion or quarantine")
    }

    /// Containment taken is not containment done: pending is reported as pending, and the host's own status is read
    /// again before anything is said.
    func testContainingAHostReportsPendingHonestly() async throws {
        let service = customer()
        service.sequences["/devices/entities/devices/v2"] = [host(laptop), host(laptop, status: "containment_pending")]
        service.answers["/devices/entities/devices-actions/v2"] = (202, #"{"meta":{"trace_id":"trace-7"},"resources":[{"id":"\#(laptop)","path":"/devices/entities/devices/v1?ids=\#(laptop)"}],"errors":[]}"#)
        let contained = try await call("contain-host", #"{"host":"\#(laptop.uppercased())","workloads":"cannot-tell"}"#, service)
        XCTAssertFalse(contained.isError, contained.text)
        XCTAssertEqual(changes(service), ["POST /devices/entities/devices-actions/v2"])
        let asked = try XCTUnwrap(service.requests.first { $0.url?.path == "/devices/entities/devices-actions/v2" })
        XCTAssertEqual(queryItems(asked)["action_name"], "contain")
        XCTAssertEqual(body(asked)["ids"] as? [String], [laptop])
        for words in ["containment pending", "Pending is not done", "Poll with action-status", "lift-containment restores", "Pion cannot tell", "was read at"] {
            XCTAssertTrue(contained.text.contains(words), "\(words): \(contained.text)")
        }
        XCTAssertEqual(contained.structured?["done"] as? Bool, false)
        let settled = customer()
        settled.sequences["/devices/entities/devices/v2"] = [host(laptop), host(laptop, status: "contained")]
        settled.answers["/devices/entities/devices-actions/v2"] = (202, #"{"resources":[{"id":"\#(laptop)"}]}"#)
        let done = try await call("contain-host", #"{"host":"\#(laptop)","workloads":"cannot-tell"}"#, settled)
        XCTAssertEqual(done.structured?["done"] as? Bool, true, done.text)
    }

    /// An answer that names another host, or a status that never shows the request, is never taken for success: the
    /// result keeps Falcon's request ID.
    func testAnAnswerForAnotherHostOrNoChangeIsUnverified() async throws {
        let service = customer()
        service.answers["/devices/entities/devices-actions/v2"] = (202, #"{"meta":{"trace_id":"trace-8"},"resources":[{"id":"\#(other)"}],"errors":[]}"#)
        let wrong = try await call("contain-host", #"{"host":"\#(laptop)","workloads":"cannot-tell"}"#, service)
        XCTAssertTrue(wrong.isError && wrong.text.contains("could not be verified: Falcon's answer did not name the host") && wrong.text.contains("trace-8"), wrong.text)
        let unchanged = self.customer(status: "contained")
        unchanged.answers["/devices/entities/devices-actions/v2"] = (202, #"{"resources":[{"id":"\#(laptop)"}]}"#)
        let lift = try await call("lift-containment", #"{"host":"\#(laptop)"}"#, unchanged)
        XCTAssertTrue(lift.isError && lift.text.contains("its status after") && lift.text.contains("It is not reported done"), lift.text)
        let refused = self.customer()
        refused.answers["/devices/entities/devices-actions/v2"] = (200, #"{"meta":{"trace_id":"trace-9"},"resources":[],"errors":[{"code":409,"message":"Device is not eligible for containment"}]}"#)
        let said = try await call("contain-host", #"{"host":"\#(laptop)","workloads":"cannot-tell"}"#, refused)
        XCTAssertTrue(said.isError && said.text.contains("Device is not eligible for containment"), said.text)
    }

    /// Nothing is sent for a malformed ID, a host Falcon does not return, a host already in the state asked for or with
    /// either change pending, or workloads that do not match what Falcon's record shows.
    func testContainmentRefusesWithoutSendingAnything() async throws {
        let cases: [(String, String, String, String)] = [
            ("contain-host", "contained", #"{"host":"\#(laptop)","workloads":"cannot-tell"}"#, "already contained"),
            ("contain-host", "containment_pending", #"{"host":"\#(laptop)","workloads":"cannot-tell"}"#, "already pending"),
            ("contain-host", "lift_containment_pending", #"{"host":"\#(laptop)","workloads":"cannot-tell"}"#, "would race"),
            ("lift-containment", "normal", #"{"host":"\#(laptop)"}"#, "not contained"),
            ("lift-containment", "lift_containment_pending", #"{"host":"\#(laptop)"}"#, "already pending"),
            ("lift-containment", "containment_pending", #"{"host":"\#(laptop)"}"#, "would race"),
            ("contain-host", "normal", #"{"host":"not-a-device","workloads":"cannot-tell"}"#, "32-character device ID"),
        ]
        for (tool, status, arguments, words) in cases {
            let service = customer(status: status)
            let result = try await call(tool, arguments, service)
            XCTAssertTrue(result.isError && result.text.contains("Nothing was changed") && result.text.contains(words), "\(tool) \(status): \(result.text)")
            XCTAssertTrue(changes(service).isEmpty, "\(tool) \(status)")
        }
        let missing = FakeService()
        missing.answers["/devices/entities/devices/v2"] = (404, #"{"resources":[],"errors":[{"code":404,"message":"Device not found"}]}"#)
        let gone = try await call("contain-host", #"{"host":"\#(laptop)","workloads":"cannot-tell"}"#, missing)
        XCTAssertTrue(gone.isError && gone.text.contains("Falcon did not return host"), gone.text)
        XCTAssertTrue(changes(missing).isEmpty)
        // An error that says nothing of the host, with or without a message, fails the read rather than leaving the
        // host for not found.
        let erred = FakeService()
        erred.answers["/devices/entities/devices/v2"] = (200, #"{"resources":[],"errors":[{"code":500}]}"#)
        let unknown = try await call("contain-host", #"{"host":"\#(laptop)","workloads":"cannot-tell"}"#, erred)
        XCTAssertTrue(unknown.isError && unknown.text.contains("error 500 without a message") && !unknown.text.contains("did not return host"), unknown.text)
        XCTAssertTrue(changes(erred).isEmpty)
    }

    /// Containing a host Falcon's record hints runs Kubernetes workloads must say so in the approval: the workloads given
    /// must be what the record hints, said as a hint, not a verified node, and the result says every workload is cut off.
    func testContainingAHostWithAKubernetesHintMustSaySoInTheApproval() async throws {
        let node = customer(extra: #","deployment_type":"DaemonSet","k8s_cluster_id":"prod-eks""#)
        let unsaid = try await call("contain-host", #"{"host":"\#(laptop)","workloads":"cannot-tell"}"#, node)
        XCTAssertTrue(unsaid.isError && unsaid.text.contains("Ask again with workloads kubernetes-suggested") && unsaid.text.contains("not verified"), unsaid.text)
        XCTAssertTrue(changes(node).isEmpty)
        let read = try await call("host", #"{"host":"\#(laptop)"}"#, node)
        for words in ["give workloads kubernetes-suggested", "suggests this host runs Kubernetes workloads (hint: ", "deployment type DaemonSet", "not verified",
                      "every pod it runs would be cut off"] {
            XCTAssertTrue(read.text.contains(words), "\(words): \(read.text)")
        }
        XCTAssertFalse(read.text.contains("is a Kubernetes node"), "a hint is never said to be a verified node")
        node.answers["/devices/entities/devices-actions/v2"] = (202, #"{"resources":[{"id":"\#(laptop)"}]}"#)
        node.sequences["/devices/entities/devices/v2"] = [host(laptop, extra: #","deployment_type":"DaemonSet""#), host(laptop, status: "contained", extra: #","deployment_type":"DaemonSet""#)]
        let said = try await call("contain-host", #"{"host":"\#(laptop)","workloads":"kubernetes-suggested"}"#, node)
        XCTAssertFalse(said.isError, said.text)
        XCTAssertTrue(said.text.contains("Containing a host cuts off every workload on it"), said.text)
    }

    func testActionStatusReadsContainmentAndIndicators() async throws {
        let service = customer(status: "lift_containment_pending", online: "offline")
        let status = try await call("action-status", #"{"host":"\#(laptop)"}"#, service)
        XCTAssertTrue(status.text.contains("lift pending") && status.text.contains("Not settled") && status.text.contains("offline now"), status.text)
        XCTAssertEqual(status.structured?["settled"] as? Bool, false)
    }

    private func indicator(_ id: String, source: String = "Pion", description: String = "Requested through Pion after the champion's approval: x", action: String = "prevent",
                           severity: String = "high", platforms: String = #"["windows","mac"]"#, value: String? = nil, modified: String? = "2026-11-23T09:00:00Z",
                           applied: Bool = true, expiration: String? = nil) -> String {
        let extra = (modified.map { #","modified_on":"\#($0)""# } ?? "") + (expiration.map { #","expiration":"\#($0)""# } ?? "")
        return #"{"id":"\#(id)","type":"sha256","value":"\#(value ?? sha256)","action":"\#(action)","severity":"\#(severity)","platforms":\#(platforms),"source":"\#(source)","description":"\#(description)","created_by":"someone","created_on":"2026-11-23T09:00:00Z","applied_globally":\#(applied),"tags":[]\#(extra)}"#
    }

    /// The client calls are made as: this connection, which Pion's record of the indicators it made is kept for.
    private func client(_ service: FakeService) -> ServiceClient {
        ServiceClient(base: falcon.endpoint, access: service, settings: falcon.settings ?? [:], account: falcon.id)
    }

    /// Records an indicator as block-ioc would, from what Falcon's answer said it made.
    private func record(_ id: String, made: String? = nil, _ service: FakeService) throws {
        let indicator = try JSONDecoder().decode(CrowdStrike.Indicator.self, from: Data((made ?? self.indicator(id)).utf8))
        try CrowdStrike.changeRecords(client(service)) { records in
            records.removeAll { $0.id == id }
            records.append(CrowdStrike.IndicatorRecord(id: id, created: Date(), made: CrowdStrike.IndicatorSnapshot(indicator)))
        }
    }

    /// An indicator is made, applied everywhere, with Falcon's warnings heeded, recorded as Pion's, and said done only
    /// when Falcon's answer names it as approved.
    func testBlockingAHashMakesAnIndicatorRecordsItAndChecksWhatFalconMade() async throws {
        let service = FakeService()
        service.answers["/iocs/combined/indicator/v1"] = (200, #"{"meta":{"pagination":{"limit":50,"total":0}},"resources":[]}"#)
        service.answers["/iocs/entities/indicators/v1"] = (201, #"{"meta":{"trace_id":"t-1"},"resources":[\#(indicator("ioc-1"))],"errors":[]}"#)
        let blocked = try await call("block-ioc", #"{"type":"sha256","value":"\#(sha256.uppercased())","action":"prevent","severity":"high","platforms":["windows","mac"],"comment":"Ransomware dropper, INV-12"}"#, service)
        XCTAssertFalse(blocked.isError, blocked.text)
        XCTAssertEqual(changes(service), ["POST /iocs/entities/indicators/v1"])
        let made = try XCTUnwrap(service.requests.first { $0.httpMethod == "POST" })
        XCTAssertEqual(queryItems(made)["ignore_warnings"], "false")
        let sent = try XCTUnwrap((body(made)["indicators"] as? [[String: Any]])?.first)
        XCTAssertEqual(sent["applied_globally"] as? Bool, true)
        XCTAssertEqual(sent["value"] as? String, sha256)
        XCTAssertEqual(body(made)["comment"] as? String, "Requested through Pion after the champion's approval: Ransomware dropper, INV-12")
        XCTAssertEqual(queryItems(service.requests.first)["filter"], "type:'sha256'+value:'\(sha256)'")
        XCTAssertTrue(blocked.text.contains("custom indicator ioc-1") && blocked.text.contains("keeps a record"), blocked.text)
        let kept = try XCTUnwrap(CrowdStrike.recorded("ioc-1", client(service)))
        XCTAssertEqual(kept.made.value, sha256)
        XCTAssertEqual(kept.made.platforms, ["mac", "windows"])
        XCTAssertEqual(kept.made.appliedGlobally, true)
        XCTAssertEqual(kept.made.modified, "2026-11-23T09:00:00Z", "the whole of what Falcon said it made is kept")
        // Made otherwise than approved: not done, but recorded, so unblock-ioc can remove it.
        let differing = FakeService()
        differing.answers["/iocs/combined/indicator/v1"] = (200, #"{"meta":{"pagination":{"total":0}},"resources":[]}"#)
        differing.answers["/iocs/entities/indicators/v1"] = (201, #"{"resources":[\#(indicator("ioc-2", action: "detect"))]}"#)
        let otherwise = try await call("block-ioc", #"{"type":"sha256","value":"\#(sha256)","action":"prevent","severity":"high","platforms":["windows","mac"],"comment":"INV-12"}"#, differing)
        XCTAssertTrue(otherwise.isError && otherwise.text.contains("not as approved") && otherwise.text.contains("Where it differs: action detect"), otherwise.text)
        XCTAssertEqual(try CrowdStrike.recorded("ioc-2", client(differing))?.made.action, "detect")
    }

    /// An indicator Falcon made somewhere other than every host, or with an expiration none asked for, is reported as
    /// Falcon made it, not done, and recorded, as Pion did make it.
    func testBlockingReportsWhatFalconMadeWhenItIsNotEverywhereOrExpires() async throws {
        for (label, made, words) in [("applied", indicator("ioc-3", applied: false), "not applied globally"),
                                     ("expiration", indicator("ioc-3", expiration: "2027-01-01T00:00:00Z"), "expiration 2027-01-01T00:00:00Z, where none was asked for")] {
            let service = FakeService()
            service.answers["/iocs/combined/indicator/v1"] = (200, #"{"meta":{"pagination":{"total":0}},"resources":[]}"#)
            service.answers["/iocs/entities/indicators/v1"] = (201, #"{"resources":[\#(made)]}"#)
            let result = try await call("block-ioc", #"{"type":"sha256","value":"\#(sha256)","action":"prevent","severity":"high","platforms":["windows","mac"],"comment":"INV-12"}"#, service)
            XCTAssertTrue(result.isError && result.text.contains("not as approved, so it is not reported done") && result.text.contains(words), "\(label): \(result.text)")
            XCTAssertFalse(result.text.contains("on every host, with no expiration"), label)
            XCTAssertNotNil(try CrowdStrike.recorded("ioc-3", client(service)), "\(label): kept, so it can be removed")
        }
    }

    func testBlockingRefusesNetworkPreventsAndIndicatorsThatExist() async throws {
        let service = FakeService()
        let domain = try await call("block-ioc", #"{"type":"domain","value":"evil.example","action":"prevent","severity":"high","platforms":["windows"],"comment":"C2, INV-12"}"#, service)
        XCTAssertTrue(domain.isError && domain.text.contains("Falcon blocks only hashes"), domain.text)
        for bad in [#"{"type":"md5","value":"xyz","action":"detect","severity":"high","platforms":["windows"],"comment":"INV-12"}"#,
                    #"{"type":"ipv4","value":"10.0.0.300","action":"detect","severity":"high","platforms":["windows"],"comment":"INV-12"}"#,
                    #"{"type":"sha256","value":"\#(sha256)","action":"prevent","severity":"high","platforms":["windows"],"expiration":"2020-01-01T00:00:00Z","comment":"INV-12"}"#] {
            let result = try await call("block-ioc", bad, service)
            XCTAssertTrue(result.isError, bad)
        }
        XCTAssertTrue(service.requests.isEmpty)
        service.answers["/iocs/combined/indicator/v1"] = (200, #"{"meta":{"pagination":{"total":1}},"resources":[\#(indicator("theirs"))]}"#)
        let theirs = try await call("block-ioc", #"{"type":"sha256","value":"\#(sha256)","action":"prevent","severity":"high","platforms":["windows"],"comment":"INV-12"}"#, service)
        XCTAssertTrue(theirs.isError && theirs.text.contains("which Pion has no record of making, so it leaves it alone"), "Pion's markers on it prove nothing: \(theirs.text)")
        try record("theirs", service)
        let ours = try await call("block-ioc", #"{"type":"sha256","value":"\#(sha256)","action":"prevent","severity":"high","platforms":["windows"],"comment":"INV-12"}"#, service)
        XCTAssertTrue(ours.isError && ours.text.contains("which Pion made through this connection"), ours.text)
        XCTAssertTrue(changes(service).isEmpty)
    }

    /// An indicator carrying Pion's source and description, which anyone can copy, is not Pion's without its record.
    func testUnblockingLeavesAnIndicatorWithCopiedMarkersButNoRecord() async throws {
        let service = FakeService()
        service.answers["/iocs/entities/indicators/v1"] = (200, #"{"resources":[\#(indicator("foreign"))]}"#)
        let refused = try await call("unblock-ioc", #"{"id":"foreign","comment":"False positive, INV-12"}"#, service)
        XCTAssertTrue(refused.isError && refused.text.contains("Pion has no record of making indicator foreign") && refused.text.contains("leaves it in place"), refused.text)
        XCTAssertTrue(changes(service).isEmpty, "nothing deleted")
        XCTAssertTrue(service.requests.isEmpty, "not even read: the record decides")
    }

    /// Two indicators for one value, one Pion's: only the recorded one, by its ID, is deleted, never by a filter; once
    /// Falcon no longer holds it, its record goes.
    func testUnblockingDeletesOnlyTheRecordedIDAndThenDropsItsRecord() async throws {
        let service = FakeService()
        try record("ours", service)
        service.sequences["/iocs/entities/indicators/v1"] = [(200, #"{"resources":[\#(indicator("ours"))]}"#), (200, #"{"resources":["ours"],"errors":[]}"#),
                                                            (404, #"{"resources":[],"errors":[{"code":404,"message":"Indicator not found","id":"ours"}]}"#)]
        service.answers["/iocs/combined/indicator/v1"] = (200, #"{"meta":{"pagination":{"total":2}},"resources":[\#(indicator("ours")),\#(indicator("theirs"))]}"#)
        let removed = try await call("unblock-ioc", #"{"id":"ours","comment":"False positive, INV-12"}"#, service)
        XCTAssertFalse(removed.isError, removed.text)
        let deletes = service.requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(queryItems(deletes[0])["ids"], "ours")
        XCTAssertNil(queryItems(deletes[0])["filter"], "never by a filter, which Falcon prefers over IDs")
        XCTAssertNil(try CrowdStrike.recorded("ours", client(service)), "the record goes once the delete is confirmed")
        let theirs = try await call("unblock-ioc", #"{"id":"theirs","comment":"INV-12"}"#, service)
        XCTAssertTrue(theirs.isError && theirs.text.contains("no record"), theirs.text)
        XCTAssertEqual(service.requests.filter { $0.httpMethod == "DELETE" }.count, 1)
    }

    /// A recorded indicator that is not exactly as Falcon's answer made it, in any field and however soon after, or whose
    /// change cannot be told, is left in place, record and all; one Falcon still holds after the delete is unverified,
    /// and its record stays.
    func testUnblockingRefusesAnIndicatorChangedSinceAndKeepsAnUnverifiedRecord() async throws {
        for (label, now) in [("value", indicator("ours", value: String(repeating: "cd", count: 32))),
                             ("action", indicator("ours", action: "detect")),
                             ("platforms ten seconds on", indicator("ours", platforms: #"["windows"]"#, modified: "2026-11-23T09:00:10Z")),
                             ("severity", indicator("ours", severity: "low")),
                             ("applied", indicator("ours", applied: false)),
                             ("modified", indicator("ours", modified: "2026-11-23T11:00:00Z")),
                             ("no modified_on", indicator("ours", modified: nil))] {
            let service = FakeService()
            try record("ours", service)
            service.answers["/iocs/entities/indicators/v1"] = (200, #"{"resources":[\#(now)]}"#)
            let refused = try await call("unblock-ioc", #"{"id":"ours","comment":"INV-12"}"#, service)
            XCTAssertTrue(refused.isError && refused.text.contains("Nothing was changed") && refused.text.contains("leaves it in place"), "\(label): \(refused.text)")
            XCTAssertTrue(changes(service).isEmpty, label)
            XCTAssertNotNil(try CrowdStrike.recorded("ours", client(service)), label)
        }
        // A record whose answer gave no modified time can never show the indicator unchanged.
        let unknowable = FakeService()
        try record("ours", made: indicator("ours", modified: nil), unknowable)
        unknowable.answers["/iocs/entities/indicators/v1"] = (200, #"{"resources":[\#(indicator("ours", modified: nil))]}"#)
        let never = try await call("unblock-ioc", #"{"id":"ours","comment":"INV-12"}"#, unknowable)
        XCTAssertTrue(never.isError && never.text.contains("modified_on was not given"), never.text)
        XCTAssertTrue(changes(unknowable).isEmpty)
        let stays = FakeService()
        try record("ours", stays)
        stays.answers["/iocs/entities/indicators/v1"] = (200, #"{"resources":[\#(indicator("ours"))]}"#)
        let unverified = try await call("unblock-ioc", #"{"id":"ours","comment":"INV-12"}"#, stays)
        XCTAssertTrue(unverified.isError && unverified.text.contains("still holds") && unverified.text.contains("keeps its record"), unverified.text)
        XCTAssertNotNil(try CrowdStrike.recorded("ours", client(stays)))
    }

    /// An answer with only errors, or for another indicator, or that cannot be read, shows neither that the indicator is
    /// there nor that it is gone: before the delete nothing is sent, and after it the removal is unverified and the
    /// record stays.
    func testAnInconclusiveReadIsNeverTakenForAbsence() async throws {
        let inconclusive = [("errors only", (200, #"{"resources":[],"errors":[{"code":500,"message":"internal error"}]}"#)),
                            ("another ID", (200, #"{"resources":[\#(indicator("someone-elses"))],"errors":[]}"#)),
                            ("no list", (200, #"{"errors":[]}"#)),
                            ("bare 404", (404, #"{"resources":[],"errors":[]}"#)),
                            ("an error without a message", (200, #"{"resources":[],"errors":[{"code":500}]}"#)),
                            ("a 404 for the route", (404, #"{"resources":[],"errors":[{"code":404,"message":"route not found"}]}"#)),
                            ("a 404 for another indicator", (404, #"{"resources":[],"errors":[{"code":404,"message":"Indicator theirs not found"}]}"#)),
                            ("a longer ID in the message", (404, #"{"resources":[],"errors":[{"code":404,"message":"Indicator ours-1234 not found"}]}"#)),
                            ("the address echoed", (404, #"{"resources":[],"errors":[{"code":404,"message":"route /iocs/entities/indicators/v1?ids=ours not found"}]}"#)),
                            ("the ID in the message alone", (404, #"{"resources":[],"errors":[{"code":404,"message":"Indicator ours not found"}]}"#)),
                            ("another ID's field", (404, #"{"resources":[],"errors":[{"code":404,"message":"not found","id":"ours-1234"}]}"#)),
                            ("a 404 beside a 500", (404, #"{"resources":[],"errors":[{"code":404,"message":"not found","id":"ours"},{"code":500}]}"#)),
                            ("a conflicting code", (404, #"{"resources":[],"errors":[{"code":500,"message":"upstream service not found","id":"ours"}]}"#)),
                            ("no code", (404, #"{"resources":[],"errors":[{"message":"not found","id":"ours"}]}"#))]
        for (label, answer) in inconclusive {
            let before = FakeService()
            try record("ours", before)
            before.answers["/iocs/entities/indicators/v1"] = answer
            let refused = try await call("unblock-ioc", #"{"id":"ours","comment":"INV-12"}"#, before)
            XCTAssertTrue(refused.isError && refused.text.contains("could not be told") && refused.text.contains("left in place"), "\(label): \(refused.text)")
            XCTAssertTrue(changes(before).isEmpty, "\(label): nothing sent")
            XCTAssertNotNil(try CrowdStrike.recorded("ours", client(before)), label)

            let after = FakeService()
            try record("ours", after)
            after.sequences["/iocs/entities/indicators/v1"] = [(200, #"{"resources":[\#(indicator("ours"))]}"#), (200, #"{"resources":["ours"]}"#), answer]
            let unverified = try await call("unblock-ioc", #"{"id":"ours","comment":"INV-12"}"#, after)
            XCTAssertTrue(unverified.isError && unverified.text.contains("is unverified") && unverified.text.contains("keeps its record"), "\(label): \(unverified.text)")
            XCTAssertEqual(after.requests.filter { $0.httpMethod == "DELETE" }.count, 1, label)
            XCTAssertNotNil(try CrowdStrike.recorded("ours", client(after)), "\(label): the record stays")
        }
        // An empty list and no errors, or a 404 whose every error names this indicator in its id field as not found,
        // is absence: before the delete the record goes.
        for (label, answer) in [("empty", (200, #"{"resources":[],"errors":[]}"#)),
                                ("structured 404", (404, #"{"resources":[],"errors":[{"code":404,"message":"not found","id":"ours"}]}"#))] {
            let gone = FakeService()
            try record("ours", gone)
            gone.answers["/iocs/entities/indicators/v1"] = answer
            let nothing = try await call("unblock-ioc", #"{"id":"ours","comment":"INV-12"}"#, gone)
            XCTAssertTrue(nothing.isError && nothing.text.contains("holds no indicator ours") && changes(gone).isEmpty, "\(label): \(nothing.text)")
            XCTAssertNil(try CrowdStrike.recorded("ours", client(gone)), label)
        }
    }

    /// The record outlasts a relaunch in the file the app names, and is kept per connection.
    func testTheRecordOutlastsARelaunchAndIsKeptPerConnection() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("falcon-indicators.json")
        defer {
            CrowdStrike.keepIndicatorRecords(at: nil)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        CrowdStrike.keepIndicatorRecords(at: file)
        let service = FakeService()
        try record("ours", service)
        CrowdStrike.keepIndicatorRecords(at: file)
        XCTAssertEqual(try CrowdStrike.recorded("ours", client(service))?.value, sha256, "read back from the file")
        let other = try CrowdStrike.containment.makeConnection(name: "Another", values: ["region": "api.us-2.crowdstrike.com"])
        XCTAssertNil(try CrowdStrike.recorded("ours", ServiceClient(base: other.endpoint, access: service, account: other.id)), "another connection's record is its own")
        let anywhere = ServiceClient(base: falcon.endpoint, access: service)
        XCTAssertThrowsError(try CrowdStrike.recorded("ours", anywhere), "no connection, no record")
    }

    private func rtr(_ service: FakeService, ps before: String, ps after: String, kill: String = #"{"complete":true,"stdout":"","stderr":"","base_command":"kill","session_id":"s-1"}"#) {
        service.sequences["/real-time-response/entities/sessions/v1"] = [(201, #"{"resources":[{"session_id":"s-1","device_id":"\#(laptop)","offline_queued":false}]}"#), (204, "{}")]
        service.sequences["/real-time-response/entities/command/v1"] = [(201, #"{"resources":[{"cloud_request_id":"r-1","session_id":"s-1"}]}"#), (200, before),
                                                                         (201, #"{"resources":[{"cloud_request_id":"r-3","session_id":"s-1"}]}"#), (200, after)]
        service.sequences["/real-time-response/entities/active-responder-command/v1"] = [(201, #"{"resources":[{"cloud_request_id":"r-2","session_id":"s-1"}]}"#),
                                                                                          (200, #"{"resources":[\#(kill)]}"#)]
    }

    private func ps(_ text: String, base: String = "ps") -> String {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [text], options: .fragmentsAllowed), encoding: .utf8)!.dropFirst().dropLast()
        return #"{"resources":[{"complete":true,"stdout":\#(escaped),"stderr":"","base_command":"\#(base)","session_id":"s-1"}]}"#
    }

    /// A process is killed only once ps shows the PID is the process approved, in a session Pion opens and closes, and
    /// is said done only once ps no longer lists it.
    func testKillingAProcessConfirmsItFirstAndAfter() async throws {
        let service = customer()
        rtr(service, ps: ps("Name      Id   Start Time\nexplorer.exe  1200  08:00\nevil.exe  4242  08:55\n"), ps: ps("Name      Id   Start Time\nexplorer.exe  1200  08:00\n"))
        let killed = try await call("rtr-kill-process", #"{"host":"\#(laptop)","pid":4242,"process":"evil.exe"}"#, service)
        XCTAssertFalse(killed.isError, killed.text)
        XCTAssertTrue(killed.text.contains("the process with that PID and name is no longer listed") && killed.text.contains("not proof that this request ended it")
                      && killed.text.contains("gone for good"), killed.text)
        XCTAssertNil(killed.structured?["done"], "an observation, not a confirmation")
        XCTAssertEqual(killed.structured?["noLongerListed"] as? Bool, true)
        let commands = service.requests.filter { $0.httpMethod == "POST" && $0.url!.path.hasPrefix("/real-time-response/entities/") && $0.url!.path != "/real-time-response/entities/sessions/v1" }
            .map { "\(body($0)["base_command"] as? String ?? "?"): \(body($0)["command_string"] as? String ?? "?")" }
        XCTAssertEqual(commands, ["ps: ps", "kill: kill 4242", "ps: ps"])
        let opened = try XCTUnwrap(service.requests.first { $0.url?.path == "/real-time-response/entities/sessions/v1" })
        XCTAssertEqual(body(opened)["queue_offline"] as? Bool, false)
        XCTAssertEqual(body(opened)["device_id"] as? String, laptop)
        XCTAssertEqual(service.requests.last?.httpMethod, "DELETE", "Pion closes its session")
        XCTAssertEqual(queryItems(service.requests.last)["session_id"], "s-1")
    }

    func testKillingRefusesAnotherProcessAnOfflineHostAndOneStillRunning() async throws {
        let offline = customer(online: "offline")
        let away = try await call("rtr-kill-process", #"{"host":"\#(laptop)","pid":4242,"process":"evil.exe"}"#, offline)
        XCTAssertTrue(away.isError && away.text.contains("needs") && away.text.contains("online"), away.text)
        XCTAssertTrue(changes(offline).isEmpty, "no session is opened")
        let mismatch = customer()
        rtr(mismatch, ps: ps("svchost.exe  4242  08:00\n"), ps: ps(""))
        let wrong = try await call("rtr-kill-process", #"{"host":"\#(laptop)","pid":4242,"process":"evil.exe"}"#, mismatch)
        XCTAssertTrue(wrong.isError && wrong.text.contains("is not evil.exe, as approved"), wrong.text)
        XCTAssertFalse(mismatch.requests.contains { $0.url?.path == "/real-time-response/entities/active-responder-command/v1" }, "nothing killed")
        XCTAssertEqual(mismatch.requests.last?.httpMethod, "DELETE", "the session is closed even so")
        let stubborn = customer()
        rtr(stubborn, ps: ps("evil.exe  4242  08:55\n"), ps: ps("evil.exe  4242  08:55\n"))
        let running = try await call("rtr-kill-process", #"{"host":"\#(laptop)","pid":4242,"process":"evil.exe"}"#, stubborn)
        XCTAssertTrue(running.isError && running.text.contains("still lists evil.exe"), running.text)
        let unread = customer()
        rtr(unread, ps: ps("evil.exe  4242  08:55\n"), ps: #"{"resources":[{"complete":true,"stdout":"","stderr":"access denied","base_command":"ps","session_id":"s-1"}]}"#)
        let unknown = try await call("rtr-kill-process", #"{"host":"\#(laptop)","pid":4242,"process":"evil.exe"}"#, unread)
        XCTAssertTrue(unknown.isError && unknown.text.contains("is unverified") && unknown.text.contains("not reported done"), unknown.text)
        for bad in [#"{"host":"\#(laptop)","pid":4,"process":"System"}"#, #"{"host":"\#(laptop)","pid":4242,"process":"evil.exe; rm -rf /"}"#] {
            let fresh = customer()
            let result = try await call("rtr-kill-process", bad, fresh)
            XCTAssertTrue(result.isError && fresh.requests.isEmpty, bad)
        }
    }

    private func alert(_ id: String, _ status: String) -> String { #"{"composite_id":"\#(id)","display_name":"CredentialDumping","status":"\#(status)","severity_name":"High"}"# }

    /// Closing reads every alert first, sends the status with Pion's comment, and is said done only once Falcon gives
    /// each alert closed.
    func testClosingAlertsReadsThemFirstAndChecksThemAfter() async throws {
        let service = FakeService()
        service.sequences["/alerts/entities/alerts/v2"] = [(200, #"{"resources":[\#(alert("cid:ind:1", "new"))]}"#), (200, #"{"resources":[\#(alert("cid:ind:1", "closed"))]}"#)]
        service.answers["/alerts/entities/alerts/v3"] = (200, #"{"meta":{"writes":{"resources_affected":1}},"resources":[],"errors":[]}"#)
        let closed = try await call("close-alert", #"{"ids":["cid:ind:1"],"comment":"False positive, INV-12"}"#, service)
        XCTAssertFalse(closed.isError, closed.text)
        let patch = try XCTUnwrap(service.requests.first { $0.httpMethod == "PATCH" })
        let parameters = (body(patch)["action_parameters"] as? [[String: String]]) ?? []
        XCTAssertEqual(parameters.first, ["name": "update_status", "value": "closed"])
        XCTAssertEqual(parameters.last?["name"], "append_comment")
        XCTAssertEqual(body(patch)["composite_ids"] as? [String], ["cid:ind:1"])
        let already = FakeService()
        already.answers["/alerts/entities/alerts/v2"] = (200, #"{"resources":[\#(alert("cid:ind:1", "closed"))]}"#)
        let twice = try await call("close-alert", #"{"ids":["cid:ind:1"],"comment":"INV-12"}"#, already)
        XCTAssertTrue(twice.isError && twice.text.contains("already closed"), twice.text)
        XCTAssertTrue(changes(already).isEmpty)
        let stuck = FakeService()
        stuck.answers["/alerts/entities/alerts/v2"] = (200, #"{"resources":[\#(alert("cid:ind:1", "new"))]}"#)
        stuck.answers["/alerts/entities/alerts/v3"] = (200, #"{"resources":[],"errors":[]}"#)
        let unverified = try await call("close-alert", #"{"ids":["cid:ind:1"],"comment":"INV-12"}"#, stuck)
        XCTAssertTrue(unverified.isError && unverified.text.contains("not reported done"), unverified.text)
        let missing = FakeService()
        missing.answers["/alerts/entities/alerts/v2"] = (200, #"{"resources":[],"errors":[{"code":404,"message":"not found"}]}"#)
        let unread = try await call("close-alert", #"{"ids":["cid:ind:9"],"comment":"INV-12"}"#, missing)
        XCTAssertTrue(unread.isError && unread.text.contains("not every alert could be read first"), unread.text)
        XCTAssertTrue(changes(missing).isEmpty)
    }

    func testReopeningAnAlertIsNotHeldButStillChecked() async throws {
        let service = FakeService()
        service.sequences["/alerts/entities/alerts/v2"] = [(200, #"{"resources":[\#(alert("cid:ind:1", "closed"))]}"#), (200, #"{"resources":[\#(alert("cid:ind:1", "reopened"))]}"#)]
        service.answers["/alerts/entities/alerts/v3"] = (200, #"{"resources":[],"errors":[]}"#)
        let reopened = try await call("update-alert-status", #"{"ids":["cid:ind:1"],"status":"reopened"}"#, service)
        XCTAssertFalse(reopened.isError, reopened.text)
        let refused = try await call("update-alert-status", #"{"ids":["cid:ind:1"],"status":"closed"}"#, FakeService())
        XCTAssertTrue(refused.isError, "closing is close-alert's, held for approval")
    }

    /// check-access sends only reads: what the actions read, and the status reads that need Real Time Response's write
    /// and admin scopes; every other write scope is said to be unverified.
    func testCheckAccessSendsOnlyReadsAndSaysWhatItCannotVerify() async throws {
        let service = FakeService()
        let empty = (200, #"{"meta":{"pagination":{"offset":0,"limit":1,"total":0}},"resources":[]}"#)
        for path in ["/devices/queries/devices/v1", "/alerts/queries/alerts/v2", "/iocs/queries/indicators/v1"] { service.answers[path] = empty }
        service.answers["/real-time-response/entities/active-responder-command/v1"] = (404, #"{"errors":[{"code":404,"message":"no such request"}]}"#)
        service.answers["/real-time-response/entities/admin-command/v1"] = (404, #"{"errors":[{"code":404,"message":"no such request"}]}"#)
        let checked = try await call("check-access", "{}", service)
        XCTAssertFalse(checked.isError, checked.text)
        for words in ["Falcon cloud US-2", "✓ Hosts (Hosts: Read)", "✓ Custom indicators (IOC Management: Read)", "✓ Real time response: Write",
                      "⚠ Appears to hold Real time response (admin): Write, which Containment must not have",
                      "Hosts: Write, Host groups: Write, Alerts: Write, IOC Management: Write: write access not verified — Falcon offers no way to list a client's scopes without attempting a change"] {
            XCTAssertTrue(checked.text.contains(words), "\(words): \(checked.text)")
        }
        XCTAssertEqual(service.requests.filter { $0.httpMethod != "GET" }.count, 0, "no request that could change anything")
        let lacking = FakeService()
        lacking.answers["/real-time-response/entities/active-responder-command/v1"] = (403, #"{"errors":[{"code":403,"message":"access denied, authorization failed"}]}"#)
        lacking.answers["/real-time-response/entities/admin-command/v1"] = (403, #"{"errors":[{"code":403,"message":"access denied, authorization failed"}]}"#)
        let without = try await call("check-access", "{}", lacking)
        XCTAssertTrue(without.text.contains("✗ Real time response: Write: the API client lacks it") && without.text.contains("✓ Holds no Real time response (admin): Write"), without.text)
        XCTAssertEqual(lacking.requests.filter { $0.httpMethod != "GET" }.count, 0)
    }
}
