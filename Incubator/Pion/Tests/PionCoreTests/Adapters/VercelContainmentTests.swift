import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class VercelContainmentTests: XCTestCase {
    private let vc = try! Vercel.containment.makeConnection(name: "Vercel Containment — Kestrel", values: ["team": VercelTests.team])
    private let project = VercelTests.project
    private let config = "/v1/security/firewall/config/active"
    private let reason = "Credential stuffing against /login, INV-42"

    override func setUp() {
        super.setUp()
        Vercel.keepContainmentRecords(at: nil)
    }

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await Vercel.$pauses.withValue([0, 0]) {
            try await Vercel.$pause.withValue({ _ in }) {
                try await Vercel.$ruleSuffix.withValue({ "t3st" }) { try await callTool(Vercel.containmentAdapter, tool, arguments, on: service, in: vc) }
            }
        }
    }

    private func client(_ service: FakeService) -> ServiceClient {
        ServiceClient(base: vc.endpoint, access: service, settings: vc.settings ?? [:], account: vc.id)
    }

    private func body(_ request: URLRequest?) -> [String: Any] {
        request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func changes(_ service: FakeService) -> [URLRequest] { service.requests.filter { $0.httpMethod != "GET" } }

    private func firewall(_ rules: String...) -> (Int, String) {
        (200, #"{"id":"cfg","version":3,"firewallEnabled":true,"rules":[\#(rules.joined(separator: ","))],"ips":[]}"#)
    }

    private func rule(id: String = "rule_1", value: String = "203.0.113.77", type: String = "ip_address", name: String = "Pion block 203.0.113.77 t3st", active: Bool = true) -> String {
        #"{"id":"\#(id)","name":"\#(name)","description":"x","active":\#(active),"conditionGroup":[{"conditions":[{"type":"\#(type)","op":"eq","value":"\#(value)"}]}],"action":{"mitigate":{"action":"deny","rateLimit":null,"redirect":null,"actionDuration":null}}}"#
    }

    func testContainmentIsItsOwnToolAndEveryActionIsHeld() async throws {
        XCTAssertEqual(Vercel.containment.name, "Vercel Containment")
        XCTAssertNotEqual(Vercel.containment.id, Vercel.preset.id)
        XCTAssertEqual(vc.adapter, "vercel-containment")
        XCTAssertNotNil(PionAdapters.all["vercel-containment"])
        XCTAssertNil(Vercel.containmentAdapter.watchedTool)
        let setup = Vercel.containmentSetup.joined(separator: "\n")
        XCTAssertTrue(setup.contains("**Member**") && setup.contains("**Owner**") && setup.contains("not finely scoped"), setup)
        let listed = try JSONSerialization.jsonObject(with: try await Vercel.containmentAdapter.tools(for: vc)) as! [String: Any]
        for tool in try XCTUnwrap(listed["tools"] as? [[String: Any]]) {
            let name = tool["name"] as! String, hints = tool["annotations"] as! [String: Any]
            if ["project", "check-access"].contains(name) {
                XCTAssertEqual(hints["readOnlyHint"] as? Bool, true, name)
            } else {
                XCTAssertEqual(hints["readOnlyHint"] as? Bool, false, name)
                XCTAssertEqual(hints["destructiveHint"] as? Bool, true, "\(name) must be held for approval")
            }
        }
    }

    /// A block adds one custom rule denying the target, as Vercel's firewall API takes it, finds it by its name in the
    /// active firewall, and keeps Pion's record of it.
    func testBlockIPSendsADenyRuleAndKeepsARecord() async throws {
        let service = FakeService()
        VercelTests.projects(service)
        service.sequences[config] = [firewall(rule(id: "rule_other", value: "198.51.100.1", name: "Someone's")), firewall(rule(id: "rule_other", value: "198.51.100.1", name: "Someone's"), rule())]
        service.answers["/v1/security/firewall/config"] = (200, "{}")
        let result = try await call("block-ip", #"{"project":"web","ip":"203.0.113.77","reason":"\#(reason)"}"#, service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Vercel made firewall rule rule_1 in web"), result.text)
        let patch = try XCTUnwrap(changes(service).first)
        XCTAssertEqual(changes(service).count, 1)
        XCTAssertEqual(patch.httpMethod, "PATCH")
        XCTAssertEqual(patch.url?.path, "/v1/security/firewall/config")
        XCTAssertEqual(queryItems(patch)["projectId"], project)
        XCTAssertEqual(queryItems(patch)["teamId"], VercelTests.team)
        let sent = body(patch)
        XCTAssertEqual(sent["action"] as? String, "rules.insert")
        XCTAssertTrue(sent["id"] is NSNull)
        let value = try XCTUnwrap(sent["value"] as? [String: Any])
        XCTAssertEqual(value["name"] as? String, "Pion block 203.0.113.77 t3st")
        XCTAssertEqual(value["description"] as? String, "Pion, after the champion's approval: " + reason)
        XCTAssertEqual(value["active"] as? Bool, true)
        let condition = try XCTUnwrap(((value["conditionGroup"] as? [[String: Any]])?.first?["conditions"] as? [[String: Any]])?.first)
        XCTAssertEqual(condition["type"] as? String, "ip_address")
        XCTAssertEqual(condition["op"] as? String, "eq")
        XCTAssertEqual(condition["value"] as? String, "203.0.113.77")
        XCTAssertEqual(((value["action"] as? [String: Any])?["mitigate"] as? [String: Any])?["action"] as? String, "deny")
        let record = try XCTUnwrap(try Vercel.owned(client(service)) { $0.id == "rule_1" })
        XCTAssertEqual(record.project, project)
        XCTAssertEqual(record.made["value"], "203.0.113.77")
    }

    func testBlockASNAndCountryUseVercelsConditionTypes() async throws {
        for (tool, arguments, type, value) in [("block-asn", #""asn":"AS64500""#, "geo_as_number", "64500"), ("block-country", #""country":"ru""#, "geo_country", "RU")] {
            Vercel.keepContainmentRecords(at: nil)
            let service = FakeService()
            VercelTests.projects(service)
            let name = "Pion block \(type == "geo_as_number" ? "AS" : "")\(value) t3st"
            service.sequences[config] = [firewall(), firewall(rule(value: value, type: type, name: name))]
            service.answers["/v1/security/firewall/config"] = (200, "{}")
            let result = try await call(tool, #"{"project":"web",\#(arguments),"reason":"\#(reason)"}"#, service)
            XCTAssertFalse(result.isError, result.text)
            let condition = (((body(changes(service).first)["value"] as? [String: Any])?["conditionGroup"] as? [[String: Any]])?.first?["conditions"] as? [[String: Any]])?.first
            XCTAssertEqual(condition?["type"] as? String, type)
            XCTAssertEqual(condition?["value"] as? String, value)
        }
    }

    /// A target a rule already denies, a malformed value, or a reason left out, changes nothing.
    func testBlockRefusesWhatIsAlreadyBlockedOrMalformed() async throws {
        let service = FakeService()
        VercelTests.projects(service)
        service.answers[config] = firewall(rule(id: "rule_theirs", name: "Theirs"))
        let held = try await call("block-ip", #"{"project":"web","ip":"203.0.113.77","reason":"\#(reason)"}"#, service)
        XCTAssertTrue(held.isError && held.text.contains("already matches"), held.text)
        for ip in ["not-an-ip", "10.0.0.0/4"] {
            let bad = try await call("block-ip", #"{"project":"web","ip":"\#(ip)","reason":"\#(reason)"}"#, service)
            XCTAssertTrue(bad.isError && bad.text.hasPrefix("Nothing was changed"), bad.text)
        }
        let noReason = try await call("block-ip", #"{"project":"web","ip":"203.0.113.9","reason":""}"#, service)
        XCTAssertTrue(noReason.isError && noReason.text.contains("give a reason"), noReason.text)
        XCTAssertTrue(changes(service).isEmpty)
    }

    /// A block Vercel accepted but that the firewall does not show is never reported done, and leaves no record.
    func testABlockNotReadBackIsNotDone() async throws {
        let service = FakeService()
        VercelTests.projects(service)
        service.answers[config] = firewall()
        service.answers["/v1/security/firewall/config"] = (200, "{}")
        let result = try await call("block-ip", #"{"project":"web","ip":"203.0.113.77","reason":"\#(reason)"}"#, service)
        XCTAssertTrue(result.isError && result.text.contains("could not be verified") && result.text.contains("Request: PATCH"), result.text)
        XCTAssertNil(try Vercel.owned(client(service)) { _ in true })
    }

    /// unblock removes only a rule Pion's record says it made, and only while it is as made.
    func testUnblockRemovesOnlyWhatPionMadeAsMade() async throws {
        let service = FakeService()
        let unowned = try await call("unblock", #"{"id":"rule_theirs"}"#, service)
        XCTAssertTrue(unowned.isError && unowned.text.contains("no record of making"), unowned.text)
        XCTAssertTrue(service.requests.isEmpty)

        try Vercel.changeOwned(client(service)) {
            $0.append(Vercel.Owned(kind: "firewall-rule", id: "rule_1", project: project, label: "ip_address 203.0.113.77", created: Date(),
                                   made: Vercel.ruleSnapshot(try! JSONDecoder().decode(Vercel.Value.self, from: Data(rule().utf8)))))
        }
        service.answers[config] = firewall(rule(active: false))
        let changed = try await call("unblock", #"{"id":"rule_1"}"#, service)
        XCTAssertTrue(changed.isError && changed.text.contains("has changed since Pion made it"), changed.text)
        XCTAssertTrue(changes(service).isEmpty)

        service.answers[config] = nil
        service.sequences[config] = [firewall(rule()), firewall()]
        service.answers["/v1/security/firewall/config"] = (200, "{}")
        let removed = try await call("unblock", #"{"id":"rule_1"}"#, service)
        XCTAssertFalse(removed.isError, removed.text)
        let patch = try XCTUnwrap(changes(service).first)
        XCTAssertEqual(queryItems(patch)["projectId"], project)
        XCTAssertEqual(body(patch)["action"] as? String, "rules.remove")
        XCTAssertEqual(body(patch)["id"] as? String, "rule_1")
        XCTAssertTrue(body(patch)["value"] is NSNull)
        XCTAssertNil(try Vercel.owned(client(service)) { $0.id == "rule_1" })
    }

    /// Pion's record of what it made is kept in its file across launches.
    func testRecordsSurviveARelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vercel-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        Vercel.keepContainmentRecords(at: file)
        try Vercel.changeOwned(client(FakeService())) { $0.append(Vercel.Owned(kind: "firewall-rule", id: "rule_9", project: project, label: "x", created: Date(), made: [:])) }
        Vercel.keepContainmentRecords(at: nil)
        XCTAssertNil(try Vercel.owned(client(FakeService())) { $0.id == "rule_9" })
        Vercel.keepContainmentRecords(at: file)
        XCTAssertNotNil(try Vercel.owned(client(FakeService())) { $0.id == "rule_9" })
        Vercel.keepContainmentRecords(at: nil)
    }

    func testEnableAttackModeSendsItsBodyAndReadsItBack() async throws {
        let service = FakeService()
        service.sequences["/v9/projects/web"] = [(200, #"{"id":"\#(project)","name":"web","security":{"attackModeEnabled":false}}"#)]
        service.answers["/v9/projects/\(project)"] = (200, #"{"id":"\#(project)","name":"web","security":{"attackModeEnabled":true}}"#)
        service.answers["/v1/security/attack-mode"] = (200, #"{"attackModeEnabled":true,"attackModeUpdatedAt":1}"#)
        let result = try await call("enable-attack-mode", #"{"project":"web","hours":6}"#, service)
        XCTAssertFalse(result.isError, result.text)
        let post = try XCTUnwrap(changes(service).first)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(body(post)["projectId"] as? String, project)
        XCTAssertEqual(body(post)["attackModeEnabled"] as? Bool, true)
        let until = try XCTUnwrap(body(post)["attackModeActiveUntil"] as? Double)
        XCTAssertEqual(until / 1_000, Date().addingTimeInterval(6 * 3_600).timeIntervalSince1970, accuracy: 60)
    }

    func testEnableProtectionPatchesVercelAuthentication() async throws {
        let service = FakeService()
        service.sequences["/v9/projects/web"] = [(200, #"{"id":"\#(project)","name":"web","ssoProtection":{"deploymentType":"preview"}}"#)]
        service.answers["/v9/projects/\(project)"] = (200, #"{"id":"\#(project)","name":"web","ssoProtection":{"deploymentType":"all_except_custom_domains"}}"#)
        let result = try await call("enable-protection", #"{"project":"web"}"#, service)
        XCTAssertFalse(result.isError, result.text)
        let patch = try XCTUnwrap(changes(service).first)
        XCTAssertEqual(patch.httpMethod, "PATCH")
        XCTAssertEqual(patch.url?.path, "/v9/projects/\(project)")
        XCTAssertEqual((body(patch)["ssoProtection"] as? [String: Any])?["deploymentType"] as? String, "all_except_custom_domains")

        let already = FakeService()
        already.answers["/v9/projects/web"] = (200, #"{"id":"\#(project)","name":"web","ssoProtection":{"deploymentType":"all"}}"#)
        let refused = try await call("enable-protection", #"{"project":"web"}"#, already)
        XCTAssertTrue(refused.isError && refused.text.contains("already covers"), refused.text)
        XCTAssertTrue(changes(already).isEmpty)
    }

    /// remove-member deletes exactly the member named, refusing the token's own user and the last owner.
    func testRemoveMemberSendsOneDeleteAndRefusesTheLastOwner() async throws {
        let members = "/v3/teams/\(VercelTests.team)/members"
        let mallory = #"{"uid":"u_mallory","email":"mallory@kestrel.example","role":"MEMBER","confirmed":true}"#
        let owner = #"{"uid":"u_owner","email":"owner@kestrel.example","role":"OWNER","confirmed":true}"#
        let me = #"{"uid":"u_pion","email":"pion@kestrel.example","role":"OWNER","confirmed":false}"#
        let service = FakeService()
        service.answers["/v2/user"] = (200, #"{"user":{"id":"u_pion","email":"pion@kestrel.example"}}"#)
        service.sequences[members] = [(200, #"{"members":[\#(owner),\#(mallory),\#(me)],"pagination":{"count":3,"next":null,"prev":null}}"#),
                                      (200, #"{"members":[\#(owner),\#(me)],"pagination":{"count":2,"next":null,"prev":null}}"#)]
        service.answers["/v1/teams/\(VercelTests.team)/members/u_mallory"] = (200, #"{"id":"u_mallory"}"#)
        let result = try await call("remove-member", #"{"member":"Mallory@kestrel.example"}"#, service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(changes(service).map { "\($0.httpMethod!) \($0.url!.path)" }, ["DELETE /v1/teams/\(VercelTests.team)/members/u_mallory"])

        for (named, said) in [("owner@kestrel.example", "only owner"), ("pion@kestrel.example", "whose token this connection uses")] {
            let refusing = FakeService()
            refusing.answers["/v2/user"] = service.answers["/v2/user"]
            refusing.answers[members] = (200, #"{"members":[\#(owner),\#(mallory),\#(me)],"pagination":{"count":3,"next":null,"prev":null}}"#)
            let refused = try await call("remove-member", #"{"member":"\#(named)"}"#, refusing)
            XCTAssertTrue(refused.isError && refused.text.contains(said), refused.text)
            XCTAssertTrue(changes(refusing).isEmpty)
        }
    }

    /// rollback reads the deployment first and sends one request for that project and deployment.
    func testRollbackChecksTheDeploymentAndSendsOneRequest() async throws {
        let service = FakeService()
        service.sequences["/v9/projects/web"] = [(200, #"{"id":"\#(project)","name":"web","targets":{"production":{"id":"dpl_bad"}}}"#)]
        service.answers["/v9/projects/\(project)"] = (200, #"{"id":"\#(project)","name":"web","targets":{"production":{"id":"dpl_good"}}}"#)
        service.answers["/v13/deployments/dpl_good"] = (200, #"{"id":"dpl_good","projectId":"\#(project)","target":"production","readyState":"READY"}"#)
        service.answers["/v1/projects/\(project)/rollback/dpl_good"] = (201, "")
        let result = try await call("rollback", #"{"project":"web","deployment":"dpl_good"}"#, service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("served by dpl_good again") && result.text.contains("dpl_bad served them before"), result.text)
        XCTAssertEqual(changes(service).map { "\($0.httpMethod!) \($0.url!.path)" }, ["POST /v1/projects/\(project)/rollback/dpl_good"])

        let other = FakeService()
        other.answers["/v9/projects/web"] = (200, #"{"id":"\#(project)","name":"web","targets":{"production":{"id":"dpl_bad"}}}"#)
        other.answers["/v13/deployments/dpl_preview"] = (200, #"{"id":"dpl_preview","projectId":"\#(project)","target":null,"readyState":"READY"}"#)
        let refused = try await call("rollback", #"{"project":"web","deployment":"dpl_preview"}"#, other)
        XCTAssertTrue(refused.isError && refused.text.contains("not a production deployment"), refused.text)
        XCTAssertTrue(changes(other).isEmpty)
    }
}
