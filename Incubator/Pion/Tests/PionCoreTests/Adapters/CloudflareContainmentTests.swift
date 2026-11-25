import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class CloudflareContainmentTests: XCTestCase {
    private let cf = try! Cloudflare.containment.makeConnection(name: "Cloudflare Containment — Kestrel", values: ["account": CloudflareTests.accountID])
    private let account = "/client/v4/accounts/\(CloudflareTests.accountID)"
    private var rules: String { "\(account)/firewall/access_rules/rules" }
    private let ruleID = "aaaabbbbccccddddeeeeffff00001111"
    private let reason = "Credential stuffing against /login, INV-42"
    private let list = "0f0f0f0f-1111-4222-8333-444455556666", gatewayRule = "1e1e1e1e-1111-4222-8333-444455556666"
    private let registration = "8a8a8a8a-1111-4222-8333-444455556666", user = "44444444-4444-4444-8444-444444444444"

    override func setUp() {
        super.setUp()
        Cloudflare.keepContainmentRecords(at: nil)
    }

    private func call(_ tool: String, _ arguments: String, _ service: FakeService, in connection: ToolConnection? = nil) async throws -> AdapterResult {
        try await Cloudflare.$pauses.withValue([0]) {
            try await Cloudflare.$pause.withValue({ _ in }) { try await callTool(Cloudflare.containmentAdapter, tool, arguments, on: service, in: connection ?? cf) }
        }
    }

    private func client(_ service: FakeService, _ connection: ToolConnection? = nil) -> ServiceClient {
        ServiceClient(base: cf.endpoint, access: service, settings: (connection ?? cf).settings ?? [:], account: (connection ?? cf).id)
    }

    /// The changes a call sent: every request but a read.
    private func changes(_ service: FakeService) -> [String] {
        service.requests.filter { $0.httpMethod != "GET" }.map { "\($0.httpMethod!) \($0.url!.path)" }
    }

    private func body(_ request: URLRequest?) -> [String: Any] {
        request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func sent(_ service: FakeService, _ method: String, _ path: String) -> URLRequest? { service.requests.last { $0.httpMethod == method && $0.url?.path == path } }

    private func envelope(_ result: String) -> (Int, String) { (200, #"{"success":true,"errors":[],"messages":[],"result":\#(result)}"#) }

    private func ruleJSON(value: String = "203.0.113.77", target: String = "ip", mode: String = "block", notes: String? = nil, modified: String = "2026-11-24T09:00:00Z", id: String? = nil) -> String {
        #"{"id":"\#(id ?? ruleID)","mode":"\#(mode)","configuration":{"target":"\#(target)","value":"\#(value)"},"notes":"\#(notes ?? "Pion, after the champion's approval: " + reason)","created_on":"2026-11-24T09:00:00Z","modified_on":"\#(modified)","scope":{"id":"\#(CloudflareTests.accountID)","type":"organization"}}"#
    }

    private func rulesPage(_ items: String...) -> (Int, String) {
        (200, #"{"success":true,"errors":[],"result":[\#(items.joined(separator: ","))],"result_info":{"page":1,"per_page":100,"count":\#(items.count),"total_count":\#(items.count),"total_pages":1}}"#)
    }

    private let pionToken = "0123456789abcdef0123456789abcdef"

    /// The token as Cloudflare verifies it, and the account audit log's entries about the registration.
    private func attribution(_ service: FakeService, _ entries: String...) {
        service.answers["\(account)/tokens/verify"] = envelope(#"{"id":"\#(pionToken)","status":"active"}"#)
        service.answers["\(account)/logs/audit"] = (200, #"{"success":true,"errors":[],"result":[\#(entries.joined(separator: ","))],"result_info":{"count":"\#(entries.count)","cursor":""}}"#)
    }

    /// An audit log entry revoking the registration: by Pion's token, or by a person in the dashboard.
    private func revocation(byPion: Bool, result: String = "success", type: String = "revoke") -> String {
        let actor = byPion ? #"{"context":"api_token","token_id":"\#(pionToken)","token_name":"Pion Containment","type":"account"}"# : #"{"context":"dash","email":"admin@kestrel.example","id":"u1","type":"user"}"#
        return #"{"id":"\#(UUID().uuidString)","action":{"type":"\#(type)","result":"\#(result)","time":"\#(Entra.iso(Date()))"},"actor":\#(actor),"resource":{"id":"\#(registration)","product":"devices","type":"registration"},"raw":{"method":"POST","uri":"/client/v4/accounts/\#(CloudflareTests.accountID)/devices/registrations/\#(type)"}}"#
    }

    /// A block that goes through: the rules for the value read whole and empty, the rule made, and read back as made.
    private func blocking(_ service: FakeService, path: String? = nil) {
        service.sequences[path ?? rules] = [rulesPage(), envelope(ruleJSON()), rulesPage(ruleJSON())]
    }

    func testContainmentIsItsOwnToolWithATokenOfItsOwn() throws {
        XCTAssertEqual(Cloudflare.containment.name, "Cloudflare Containment")
        XCTAssertNotEqual(Cloudflare.containment.id, Cloudflare.preset.id)
        XCTAssertNotNil(UUID(uuidString: Cloudflare.containment.id))
        XCTAssertEqual(cf.endpoint.absoluteString, "https://api.cloudflare.com/client/v4")
        XCTAssertEqual(cf.tokenScheme, "Bearer")
        XCTAssertEqual(cf.adapter, "cloudflare-containment")
        XCTAssertNotNil(PionAdapters.all["cloudflare-containment"])
        XCTAssertNil(Cloudflare.containmentAdapter.watchedTool)
        XCTAssertTrue(PionCatalogue.entries.contains { $0.id == Cloudflare.containment.id })
        let setup = Cloudflare.containmentSetup.joined(separator: "\n")
        for permission in Cloudflare.containmentPermissions + Cloudflare.containmentZonePermissions { XCTAssertTrue(setup.contains("**\(permission)**"), permission) }
        XCTAssertTrue(setup.contains("Pion Containment") && setup.contains("apart from Pion Detection's"), setup)
    }

    /// Every change is held for approval and says what recovering from it involves; the reads are not held.
    func testEveryActionIsHeldForApprovalAndSaysHowToRecover() async throws {
        let listed = try JSONSerialization.jsonObject(with: try await Cloudflare.containmentAdapter.tools(for: cf)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        func tool(_ name: String) throws -> [String: Any] { try XCTUnwrap(tools.first { $0["name"] as? String == name }, name) }
        let recovery: [String: [String]] = [
            "block-ip": ["unblock with the rule's ID removes it", "keep a record that Pion made it", "whoever made it"],
            "block-asn": ["unblock with the rule's ID", "customers included"],
            "block-country": ["unblock with the rule's ID", "only Enterprise plans"],
            "unblock": ["block-ip, block-asn or block-country again restores", "by its ID", "whatever its notes say"],
            "revoke-access-sessions": ["sign in again", "cannot be reversed", "suspend it at the identity provider"],
            "gateway-block": ["gateway-unblock with the same value removes it", "Pion's own Gateway list"],
            "gateway-unblock": ["gateway-block again restores", "resolve or reach it again"],
            "revoke-device": ["unrevoke the registration, or have its user enrol the device in WARP again, in the Zero Trust dashboard", "Pion offers no unrevoke", "confirms the state, not who changed it"],
        ]
        for (name, words) in recovery {
            let annotations = try XCTUnwrap(try tool(name)["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false, name)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, true, name)
            let summary = try XCTUnwrap(try tool(name)["description"] as? String)
            XCTAssertTrue(summary.contains("Recovery:"), name)
            for word in words { XCTAssertTrue(summary.contains(word), "\(name) says \(word): \(summary)") }
        }
        for name in ["access-user", "device", "action-status", "check-access"] {
            XCTAssertEqual((try tool(name)["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true, name)
        }
        XCTAssertEqual(tools.count, recovery.count + 4)
    }

    func testTargetsAreReadAsCloudflareWritesThem() throws {
        XCTAssertEqual(try Cloudflare.ipTarget("2001:DB8:0::1"), Cloudflare.Target(target: "ip6", value: "2001:db8::1"))
        XCTAssertEqual(try Cloudflare.ipTarget(" 198.51.100.0/24 "), Cloudflare.Target(target: "ip_range", value: "198.51.100.0/24"))
        XCTAssertEqual(try Cloudflare.ipTarget("2001:db8::/48"), Cloudflare.Target(target: "ip_range", value: "2001:db8::/48"))
        XCTAssertEqual(try Cloudflare.asnTarget("as64500"), Cloudflare.Target(target: "asn", value: "AS64500"))
        XCTAssertEqual(try Cloudflare.countryTarget("ru"), Cloudflare.Target(target: "country", value: "RU"))
        for bad in ["evil", "198.51.100.0/20", "198.51.100.7/24/1", "2001:db8::/40"] { XCTAssertThrowsError(try Cloudflare.ipTarget(bad), bad) }
        XCTAssertThrowsError(try Cloudflare.asnTarget("ASX"))
        XCTAssertThrowsError(try Cloudflare.countryTarget("Russia"))
    }

    /// A block reads every rule for the value first, sends one rule that blocks it with Pion's note, reads it back, and
    /// keeps Pion's record of it.
    func testBlockIPMakesOneRuleReadsItBackAndKeepsPionsRecord() async throws {
        let service = FakeService()
        blocking(service)
        let result = try await call("block-ip", #"{"ip":"203.0.113.77","reason":"\#(reason)"}"#, service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(changes(service), ["POST \(rules)"])
        let made = body(sent(service, "POST", rules))
        XCTAssertEqual(made["mode"] as? String, "block")
        XCTAssertEqual(made["configuration"] as? [String: String], ["target": "ip", "value": "203.0.113.77"])
        XCTAssertEqual(made["notes"] as? String, "Pion, after the champion's approval: " + reason)
        let first = queryItems(service.requests.first)
        XCTAssertEqual(first["configuration.value"], "203.0.113.77")
        XCTAssertEqual(first["configuration.target"], "ip")
        XCTAssertEqual(first["match"], "all")
        XCTAssertEqual(result.structured?["done"] as? Bool, true)
        XCTAssertEqual(result.structured?["id"] as? String, ruleID)
        XCTAssertTrue(result.text.contains("Recovery: unblock") && result.text.contains("Only rules for exactly 203.0.113.77 were checked"), result.text)
        let record = try XCTUnwrap(try Cloudflare.owned(client(service)) { $0.kind == "ip-access-rule" && $0.id == ruleID })
        XCTAssertEqual(record.scope, "account:\(CloudflareTests.accountID)")
        XCTAssertFalse(record.changedSinceCreation)
    }

    func testBlockRefusesWhatIsAlreadyHeldOrCannotBeReadWhole() async throws {
        let cases: [((Int, String), String)] = [
            (rulesPage(ruleJSON(mode: "challenge", notes: "someone else's")), "already holds 203.0.113.77, which Pion has no record of making"),
            ((200, #"{"success":false,"errors":[{"code":10000,"message":"internal"}],"result":null}"#), "internal"),
            ((200, #"{"success":true,"errors":[],"result":[\#(ruleJSON(value: "203.0.113.1"))],"result_info":{"page":1,"per_page":100,"count":1,"total_count":3,"total_pages":1}}"#), "said 3 match"),
            ((200, #"{"success":true,"errors":[{"code":1}],"result":[]}"#), "error 1 without a message"),
        ]
        for (answer, said) in cases {
            let service = FakeService()
            service.answers[rules] = answer
            let result = try await call("block-ip", #"{"ip":"203.0.113.77","reason":"\#(reason)"}"#, service)
            XCTAssertTrue(result.isError && result.text.contains(said), "\(said): \(result.text)")
            XCTAssertTrue(changes(service).isEmpty, said)
        }
        let malformed = FakeService()
        for (tool, arguments) in [("block-ip", #"{"ip":"evil","reason":"\#(reason)"}"#), ("block-ip", #"{"ip":"198.51.100.0/20","reason":"\#(reason)"}"#),
                                  ("block-asn", #"{"asn":"ASX","reason":"\#(reason)"}"#), ("block-country", #"{"country":"Russia","reason":"\#(reason)"}"#),
                                  ("block-ip", #"{"ip":"203.0.113.77","reason":""}"#), ("unblock", #"{"id":"1 OR 1"}"#)] {
            let result = try await call(tool, arguments, malformed)
            XCTAssertTrue(result.isError && result.text.contains("Nothing was changed"), "\(arguments): \(result.text)")
        }
        XCTAssertTrue(malformed.requests.isEmpty)
    }

    /// Pion records a rule only from a plain answer: success, no error, and the rule as asked; anything else is
    /// unverified and leaves no record.
    func testOwnershipRestsOnlyOnAPlainCreateAnswer() async throws {
        let cases: [((Int, String), String)] = [
            ((200, #"{"success":true,"errors":[{"code":10000}],"result":\#(ruleJSON())}"#), "carried errors"),
            ((200, #"{"success":false,"errors":[],"result":\#(ruleJSON())}"#), "did not say it succeeded"),
            (envelope(ruleJSON(mode: "challenge")), "not as asked (mode challenge)"),
            (envelope(ruleJSON(value: "203.0.113.78")), "not as asked (target ip 203.0.113.78)"),
            (envelope(#"{"mode":"block"}"#), "without naming the rule"),
            (envelope(ruleJSON().replacingOccurrences(of: CloudflareTests.accountID, with: "ffffffffffffffffffffffffffffffff")), "not as asked (scope"),
        ]
        for (answer, said) in cases {
            let service = FakeService()
            service.sequences[rules] = [rulesPage(), answer, rulesPage(ruleJSON())]
            let result = try await call("block-ip", #"{"ip":"203.0.113.77","reason":"\#(reason)"}"#, service)
            XCTAssertTrue(result.isError && result.text.contains(said) && result.text.contains("not reported done"), "\(said): \(result.text)")
            XCTAssertTrue(result.text.contains("Request: POST /client/v4/accounts/\(CloudflareTests.accountID)/firewall/access_rules/rules"), result.text)
            XCTAssertNil(try Cloudflare.owned(client(service)) { $0.kind == "ip-access-rule" }, said)
        }
    }

    /// A rule that reads back otherwise than made is recorded as changed, and unblock then leaves it to the dashboard.
    func testARuleReadBackOtherwiseIsRecordedChangedAndLeftAlone() async throws {
        let service = FakeService()
        service.sequences[rules] = [rulesPage(), envelope(ruleJSON()), rulesPage(ruleJSON(modified: "2026-11-24T09:05:00Z"))]
        let result = try await call("block-ip", #"{"ip":"203.0.113.77","reason":"\#(reason)"}"#, service)
        XCTAssertTrue(result.isError && result.text.contains("could not be verified") && result.text.contains("modified_on"), result.text)
        XCTAssertEqual(try Cloudflare.owned(client(service)) { $0.id == ruleID }?.changedSinceCreation, true)
        let unblock = try await call("unblock", #"{"id":"\#(ruleID)"}"#, service)
        XCTAssertTrue(unblock.isError && unblock.text.contains("not as Cloudflare said it made it"), unblock.text)
        XCTAssertFalse(changes(service).contains { $0.hasPrefix("DELETE") })
    }

    /// unblock removes only a rule Pion's record says it made, still as made, by its ID, and says removed only once
    /// Cloudflare names it as removed and lists it no more.
    func testUnblockRemovesOnlyPionsOwnUnchangedRuleByID() async throws {
        let stranger = FakeService()
        let refused = try await call("unblock", #"{"id":"\#(ruleID)"}"#, stranger)
        XCTAssertTrue(refused.isError && refused.text.contains("no record of making"), refused.text)
        XCTAssertTrue(stranger.requests.isEmpty)

        for (after, deleted, said) in [(rulesPage(), #"{"id":"\#(ruleID)"}"#, ""), (rulesPage(), #"{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}"#, "named bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
                                       (rulesPage(ruleJSON()), #"{"id":"\#(ruleID)"}"#, "still lists")] {
            Cloudflare.keepContainmentRecords(at: nil)
            let service = FakeService()
            blocking(service)
            _ = try await call("block-ip", #"{"ip":"203.0.113.77","reason":"\#(reason)"}"#, service)
            service.sequences[rules] = [rulesPage(ruleJSON()), after]
            service.answers["\(rules)/\(ruleID)"] = envelope(deleted)
            let result = try await call("unblock", #"{"id":"\#(ruleID)"}"#, service)
            XCTAssertEqual(changes(service), ["POST \(rules)", "DELETE \(rules)/\(ruleID)"])
            XCTAssertNil(sent(service, "DELETE", "\(rules)/\(ruleID)")?.httpBody, "an account's rule takes no body")
            let kept = try Cloudflare.owned(client(service)) { $0.id == ruleID } != nil
            if said.isEmpty {
                XCTAssertTrue(!result.isError && result.structured?["done"] as? Bool == true && result.text.contains("Recovery: block-ip"), result.text)
                XCTAssertFalse(kept, "the record is dropped")
            } else {
                XCTAssertTrue(result.isError && result.text.contains(said) && result.text.contains("Pion keeps its record"), "\(said): \(result.text)")
                XCTAssertTrue(kept, said)
            }
        }

        let changed = FakeService()
        blocking(changed)
        Cloudflare.keepContainmentRecords(at: nil)
        _ = try await call("block-ip", #"{"ip":"203.0.113.77","reason":"\#(reason)"}"#, changed)
        changed.sequences[rules] = [rulesPage(ruleJSON(notes: "edited by someone"))]
        let left = try await call("unblock", #"{"id":"\#(ruleID)"}"#, changed)
        XCTAssertTrue(left.isError && left.text.contains("changed since Pion made it") && left.text.contains("notes"), left.text)
        XCTAssertFalse(changes(changed).contains { $0.hasPrefix("DELETE") })
    }

    /// A zone's rule is made in that zone and removed from it alone.
    func testAZoneRuleIsMadeAndRemovedInItsZoneAlone() async throws {
        let service = FakeService()
        CloudflareTests.zone(service)
        let zoneRules = "/client/v4/zones/\(CloudflareTests.zoneID)/firewall/access_rules/rules"
        let zoneRule = ruleJSON(value: "AS64500", target: "asn").replacingOccurrences(of: #","scope":{"id":"\#(CloudflareTests.accountID)","type":"organization"}"#, with: "")
        service.sequences[zoneRules] = [rulesPage(), envelope(zoneRule), rulesPage(zoneRule), rulesPage(zoneRule), rulesPage()]
        service.answers["\(zoneRules)/\(ruleID)"] = envelope(#"{"id":"\#(ruleID)"}"#)
        let blocked = try await call("block-asn", #"{"asn":"64500","zone":"kestrel.example","reason":"\#(reason)"}"#, service)
        XCTAssertFalse(blocked.isError, blocked.text)
        XCTAssertEqual(try Cloudflare.owned(client(service)) { $0.id == ruleID }?.scope, "zone:\(CloudflareTests.zoneID)")
        let removed = try await call("unblock", #"{"id":"\#(ruleID)"}"#, service)
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertEqual(changes(service), ["POST \(zoneRules)", "DELETE \(zoneRules)/\(ruleID)"])
        XCTAssertEqual(body(sent(service, "DELETE", "\(zoneRules)/\(ruleID)"))["cascade"] as? String, "none", "this zone alone")
    }

    /// Revoking a user's sessions reads the user whole by email, refuses when they have none, and is confirmed only once
    /// their sessions, read again, are gone.
    func testRevokingSessionsIsConfirmedOnlyWhenTheyAreGone() async throws {
        let users = "\(account)/access/users", sessions = "\(account)/access/users/\(user)/active_sessions"
        let person = CloudflareTests.page(#"{"id":"\#(user)","email":"eve@kestrel.example","name":"Eve"}"#, total: 1)
        let one = CloudflareTests.page(#"{"name":"nonce1","expiration":1795000000,"metadata":{"apps":{}}}"#, total: 1), none = CloudflareTests.page("", total: 0)
        for (answer, after, said) in [("true", none, ""), ("false", none, "rather than true"), ("true", one, "still lists 1 active session")] {
            let service = FakeService()
            service.answers[users] = person
            service.sequences[sessions] = [one, after, after, after]
            service.answers["\(account)/access/organizations/revoke_user"] = envelope(answer)
            let result = try await call("revoke-access-sessions", #"{"user":"Eve@kestrel.example"}"#, service)
            XCTAssertEqual(changes(service), ["POST \(account)/access/organizations/revoke_user"])
            XCTAssertEqual(body(sent(service, "POST", "\(account)/access/organizations/revoke_user")) as? [String: String], ["email": "eve@kestrel.example"])
            if said.isEmpty { XCTAssertTrue(!result.isError && result.structured?["done"] as? Bool == true && result.text.contains("sign in again"), result.text) }
            else { XCTAssertTrue(result.isError && result.text.contains(said) && result.text.contains("not reported done"), "\(said): \(result.text)") }
        }
        let idle = FakeService()
        idle.answers[users] = person
        idle.answers[sessions] = none
        let nothing = try await call("revoke-access-sessions", #"{"user":"eve@kestrel.example"}"#, idle)
        XCTAssertTrue(nothing.isError && nothing.text.contains("no active Access session") && changes(idle).isEmpty, nothing.text)
        let unknown = FakeService()
        unknown.answers[users] = CloudflareTests.page("", total: 0)
        let missing = try await call("revoke-access-sessions", #"{"user":"eve@kestrel.example"}"#, unknown)
        XCTAssertTrue(missing.isError && missing.text.contains("has no user") && changes(unknown).isEmpty, missing.text)
    }

    /// gateway-block makes Pion's list and its rule once, adds each value only after reading the list whole, and says
    /// when an allow rule ahead may let it through; gateway-unblock removes only what Pion added.
    func testGatewayBlockUsesPionsOwnListAndUnblockRemovesOnlyWhatItAdded() async throws {
        let service = FakeService()
        let lists = "\(account)/gateway/lists", rulesPath = "\(account)/gateway/rules", items = "\(account)/gateway/lists/\(list)/items"
        let listJSON = #"{"id":"\#(list)","name":"Pion blocked domains","type":"DOMAIN","description":"Made by Pion for values the champion approved blocking; Pion adds and removes only its own items."}"#
        let traffic = "any(dns.domains[*] in $\(list))"
        let ruleJSON = #"{"id":"\#(gatewayRule)","name":"Pion: block the domains in Pion's list","action":"block","enabled":true,"filters":["dns"],"traffic":"\#(traffic)","precedence":5}"#
        let allow = #"{"id":"2d2d2d2d-1111-4222-8333-444455556666","name":"Allow partners","action":"allow","enabled":true,"filters":["dns"],"precedence":1}"#
        func itemsPage(_ values: String...) -> (Int, String) {
            (200, #"{"success":true,"errors":[],"result":[\#(values.map { #"{"value":"\#($0)","description":"Pion, after the champion's approval: \#(reason)","created_at":"2026-11-24T09:00:00Z"}"# }.joined(separator: ","))],"result_info":{"page":1,"per_page":1000,"count":\#(values.count),"total_count":\#(values.count),"total_pages":1}}"#)
        }
        service.answers[lists] = envelope(listJSON)
        service.sequences[rulesPath] = [envelope(ruleJSON)]
        service.answers[rulesPath] = (200, #"{"success":true,"errors":[],"result":[\#(ruleJSON),\#(allow)],"result_info":{"count":2,"total_count":2}}"#)
        service.sequences[items] = [itemsPage("evil.example")]
        let first = try await call("gateway-block", #"{"value":"Evil.Example","reason":"\#(reason)"}"#, service)
        XCTAssertFalse(first.isError, first.text)
        XCTAssertEqual(changes(service), ["POST \(lists)", "POST \(rulesPath)"])
        let made = body(sent(service, "POST", lists))
        XCTAssertEqual(made["name"] as? String, "Pion blocked domains")
        XCTAssertEqual(made["type"] as? String, "DOMAIN")
        XCTAssertEqual((made["items"] as? [[String: String]])?.first?["value"], "evil.example")
        let rule = body(sent(service, "POST", rulesPath))
        XCTAssertEqual(rule["traffic"] as? String, traffic)
        XCTAssertEqual(rule["action"] as? String, "block")
        XCTAssertEqual(rule["filters"] as? [String], ["dns"])
        XCTAssertTrue(first.text.contains("may let the value through") && first.text.contains("Allow partners"), first.text)
        XCTAssertEqual(first.structured?["blocked"] as? Bool, true)

        service.sequences["\(account)/gateway/lists/\(list)"] = [envelope(listJSON), envelope(listJSON)]
        service.sequences[items] = [itemsPage("evil.example"), itemsPage("evil.example", "bad.example")]
        let second = try await call("gateway-block", #"{"value":"bad.example","reason":"\#(reason)"}"#, service)
        XCTAssertFalse(second.isError, second.text)
        XCTAssertEqual(changes(service).suffix(1), ["PATCH \(account)/gateway/lists/\(list)"], "the list and rule are made once")
        XCTAssertEqual((body(sent(service, "PATCH", "\(account)/gateway/lists/\(list)"))["append"] as? [[String: String]])?.first?["value"], "bad.example")

        service.sequences["\(account)/gateway/lists/\(list)"] = [envelope(listJSON)]
        service.sequences[items] = [itemsPage("evil.example", "bad.example")]
        let again = try await call("gateway-block", #"{"value":"bad.example","reason":"\#(reason)"}"#, service)
        XCTAssertTrue(again.isError && again.text.contains("already holds bad.example"), again.text)

        let stranger = try await call("gateway-unblock", #"{"value":"other.example"}"#, service)
        XCTAssertTrue(stranger.isError && stranger.text.contains("no record of adding"), stranger.text)
        service.sequences["\(account)/gateway/lists/\(list)"] = [envelope(listJSON), envelope(listJSON)]
        service.sequences[items] = [itemsPage("evil.example", "bad.example"), itemsPage("bad.example")]
        let removed = try await call("gateway-unblock", #"{"value":"evil.example"}"#, service)
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertEqual(body(sent(service, "PATCH", "\(account)/gateway/lists/\(list)"))["remove"] as? [String], ["evil.example"])
        XCTAssertNil(try Cloudflare.owned(client(service)) { $0.kind == "gateway-item" && $0.label == "evil.example" })
        XCTAssertNotNil(try Cloudflare.owned(client(service)) { $0.kind == "gateway-item" && $0.label == "bad.example" })

        service.sequences["\(account)/gateway/lists/\(list)"] = [envelope(listJSON.replacingOccurrences(of: "Pion blocked domains", with: "Renamed"))]
        let tampered = try await call("gateway-unblock", #"{"value":"bad.example"}"#, service)
        XCTAssertTrue(tampered.isError && tampered.text.contains("not as Pion made it"), tampered.text)
    }

    /// A WARP registration is read through a listing of that ID alone, refused when already as asked, and confirmed
    /// only when, read again, it is.
    func testRevokingADeviceRegistration() async throws {
        let registrations = "\(account)/devices/registrations"
        func reg(revoked: String?, id: String? = nil) -> (Int, String) {
            (200, #"{"success":true,"errors":[],"result":[{"id":"\#(id ?? registration)","device":{"id":"d1","name":"LT-0423"},"user":{"email":"eve@kestrel.example"},"revoked_at":\#(revoked.map { #""\#($0)""# } ?? "null")}],"result_info":{"count":1,"per_page":50,"total_count":1}}"#)
        }
        let service = FakeService()
        let now = Entra.iso(Date().addingTimeInterval(1))
        service.sequences[registrations] = [reg(revoked: nil), reg(revoked: now)]
        service.answers["\(registrations)/revoke"] = envelope("null")
        let revoked = try await call("revoke-device", #"{"id":"\#(registration)"}"#, service)
        XCTAssertTrue(!revoked.isError && revoked.structured?["done"] as? Bool == true, revoked.text)
        XCTAssertTrue(revoked.text.contains("it is revoked at \(now) — this confirms the state, not who changed it") && revoked.text.contains("in the Zero Trust dashboard"), revoked.text)
        XCTAssertEqual(changes(service), ["POST \(registrations)/revoke"])
        XCTAssertEqual(queryItems(sent(service, "POST", "\(registrations)/revoke"))["id"], registration)
        XCTAssertEqual(queryItems(service.requests.first)["id"], registration)
        XCTAssertEqual(queryItems(service.requests.first)["status"], "all")

        let cases: [(String, [(Int, String)], String)] = [
            ("revoke-device", [reg(revoked: "2026-11-24T09:00:00Z")], "already revoked"),
            ("revoke-device", [reg(revoked: nil, id: "99999999-1111-4222-8333-444455556666")], "could not be read whole"),
            ("revoke-device", [CloudflareTests.page("", total: 0)], "lists no WARP registration"),
        ]
        for (tool, answers, said) in cases {
            let refused = FakeService()
            refused.sequences[registrations] = answers
            let result = try await call(tool, #"{"id":"\#(registration)"}"#, refused)
            XCTAssertTrue(result.isError && result.text.contains(said) && changes(refused).isEmpty, "\(said): \(result.text)")
        }
        XCTAssertNil(try Cloudflare.owned(client(service)) { _ in true }, "a revocation leaves no record of Pion's")

        let stuck = FakeService()
        stuck.answers[registrations] = reg(revoked: nil)
        stuck.answers["\(registrations)/revoke"] = envelope("null")
        let unverified = try await call("revoke-device", #"{"id":"\#(registration)"}"#, stuck)
        XCTAssertTrue(unverified.isError && unverified.text.contains("could not be confirmed") && unverified.text.contains("Request: POST"), unverified.text)
    }

    /// Giving a revocation back is the dashboard's alone: even with Pion's own successful revocation in the audit log,
    /// listed before an administrator's, there is no unrevoke operation, and an attempt sends nothing.
    func testNoUnrevokeEvenWithPionsOwnRevocationInTheAuditLog() async throws {
        let registrations = "\(account)/devices/registrations"
        let service = FakeService()
        service.answers[registrations] = (200, #"{"success":true,"errors":[],"result":[{"id":"\#(registration)","revoked_at":"\#(Entra.iso(Date()))"}],"result_info":{"count":1,"per_page":50,"total_count":1}}"#)
        attribution(service, revocation(byPion: true), revocation(byPion: false))
        service.answers["\(registrations)/unrevoke"] = envelope("null")
        let listed = try JSONSerialization.jsonObject(with: try await Cloudflare.containmentAdapter.tools(for: cf)) as! [String: Any]
        let names = (listed["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertFalse(names.contains { $0.contains("unrevoke") }, "\(names)")
        do {
            _ = try await call("unrevoke-device", #"{"id":"\#(registration)"}"#, service)
            XCTFail("there is no unrevoke operation")
        } catch {}
        XCTAssertTrue(changes(service).isEmpty, "no request at all: \(changes(service))")
        XCTAssertTrue(service.requests.isEmpty)
    }

    /// A rule is found by its ID across the whole account or zone, never among the rules for its old value: one whose
    /// value someone changed is neither gone nor removable, before or after a removal.
    func testARuleWhoseValueChangedUnderTheSameIDIsNeverTakenAsGoneOrRemoved() async throws {
        for afterDelete in [false, true] {
            Cloudflare.keepContainmentRecords(at: nil)
            let service = FakeService()
            blocking(service)
            _ = try await call("block-ip", #"{"ip":"203.0.113.77","reason":"\#(reason)"}"#, service)
            let moved = rulesPage(ruleJSON(value: "203.0.113.99", modified: "2026-11-24T10:00:00Z"))
            service.sequences[rules] = afterDelete ? [rulesPage(ruleJSON()), moved] : [moved]
            service.answers["\(rules)/\(ruleID)"] = envelope(#"{"id":"\#(ruleID)"}"#)
            let result = try await call("unblock", #"{"id":"\#(ruleID)"}"#, service)
            XCTAssertTrue(result.isError && result.text.contains("changed since Pion made it") && result.text.contains("203.0.113.99"), "\(afterDelete): \(result.text)")
            XCTAssertTrue(result.text.contains("keeps its record"), result.text)
            XCTAssertNotNil(try Cloudflare.owned(client(service)) { $0.kind == "ip-access-rule" && $0.id == ruleID }, "the record is kept")
            XCTAssertEqual(changes(service).contains("DELETE \(rules)/\(ruleID)"), afterDelete)
            let byID = service.requests.filter { $0.url?.path == rules }.suffix(afterDelete ? 2 : 1)
            XCTAssertTrue(byID.allSatisfy { queryItems($0)["configuration.value"] == nil }, "the whole scope is read, not one value's rules")
        }
    }

    /// Any sign that more follows, from a list Cloudflare normally gives in one answer, leaves it incomplete: Pion's list
    /// is then neither found gone nor used, and its records stay.
    func testContinuationEvidenceLeavesAListIncompleteAndRecordsKept() async throws {
        for marker in [#""cursor":"next","count":1"#, #""total_pages":2,"count":1"#, #""total_count":3,"count":1"#] {
            Cloudflare.keepContainmentRecords(at: nil)
            let service = try await gatewayBlocked()
            service.answers["\(account)/gateway/lists/\(list)"] = (404, #"{"success":false,"errors":[{"code":7003,"message":"No route for the URI"}]}"#)
            service.answers["\(account)/gateway/lists"] = (200, #"{"success":true,"errors":[],"result":[{"id":"aaaaaaaa-1111-4222-8333-444455556666","name":"Other","type":"DOMAIN"}],"result_info":{\#(marker)}}"#)
            let result = try await call("gateway-unblock", #"{"value":"evil.example"}"#, service)
            XCTAssertTrue(result.isError && result.text.contains("could not be read whole"), "\(marker): \(result.text)")
            XCTAssertNotNil(try Cloudflare.owned(client(service)) { $0.kind == "gateway-list" && $0.id == list }, "\(marker): the list's record is kept")
            XCTAssertNotNil(try Cloudflare.owned(client(service)) { $0.kind == "gateway-item" && $0.label == "evil.example" }, "\(marker): the item's record is kept")
            XCTAssertFalse(changes(service).contains { $0.hasPrefix("PATCH") }, marker)
        }
        let one = FakeService()
        one.answers["\(account)/gateway/rules"] = (200, #"{"success":true,"errors":[],"result":[],"result_info":{"cursor":"next"}}"#)
        let listing = try await Cloudflare.list(client(one), ["accounts", CloudflareTests.accountID, "gateway", "rules"], query: [:], as: Cloudflare.Item.self, paging: .single, size: 0)
        XCTAssertFalse(listing.complete, "an empty answer with a cursor is not whole")
    }

    /// An entry someone put in place of the one Pion added, with the same value, is left to the dashboard; so is one
    /// whose time Cloudflare never gave, as it cannot be told apart.
    func testAReplacedGatewayEntryIsLeftToTheDashboard() async throws {
        let service = try await gatewayBlocked()
        let listJSON = #"{"id":"\#(list)","name":"Pion blocked domains","type":"DOMAIN","description":"Made by Pion for values the champion approved blocking; Pion adds and removes only its own items."}"#
        service.answers["\(account)/gateway/lists/\(list)"] = envelope(listJSON)
        service.answers["\(account)/gateway/lists/\(list)/items"] = (200, #"{"success":true,"errors":[],"result":[{"value":"evil.example","description":"ops: keep blocked","created_at":"2026-11-24T11:00:00Z"}],"result_info":{"page":1,"per_page":1000,"count":1,"total_count":1,"total_pages":1}}"#)
        let replaced = try await call("gateway-unblock", #"{"value":"evil.example"}"#, service)
        XCTAssertTrue(replaced.isError && replaced.text.contains("not, or cannot be shown to be, the one Pion added") && replaced.text.contains("Reusable components › Lists"), replaced.text)
        XCTAssertFalse(changes(service).contains { $0.hasPrefix("PATCH") })
        XCTAssertNotNil(try Cloudflare.owned(client(service)) { $0.kind == "gateway-item" && $0.label == "evil.example" })

        Cloudflare.keepContainmentRecords(at: nil)
        let untimed = try await gatewayBlocked(created: nil)
        let added = try await call("gateway-unblock", #"{"value":"evil.example"}"#, untimed)
        XCTAssertTrue(added.isError && added.text.contains("gave no time when Pion added"), added.text)
        XCTAssertFalse(changes(untimed).contains { $0.hasPrefix("PATCH") })
    }

    /// A service where gateway-block has made Pion's list and rule with evil.example in it.
    private func gatewayBlocked(created: String? = "2026-11-24T09:00:00Z") async throws -> FakeService {
        let service = FakeService()
        let lists = "\(account)/gateway/lists", rulesPath = "\(account)/gateway/rules"
        let listJSON = #"{"id":"\#(list)","name":"Pion blocked domains","type":"DOMAIN","description":"Made by Pion for values the champion approved blocking; Pion adds and removes only its own items."}"#
        let ruleJSON = #"{"id":"\#(gatewayRule)","name":"Pion: block the domains in Pion's list","action":"block","enabled":true,"filters":["dns"],"traffic":"any(dns.domains[*] in $\#(list))","precedence":5}"#
        service.answers[lists] = envelope(listJSON)
        service.answers["\(lists)/\(list)"] = envelope(listJSON)
        service.sequences[rulesPath] = [envelope(ruleJSON)]
        service.answers[rulesPath] = (200, #"{"success":true,"errors":[],"result":[\#(ruleJSON)],"result_info":{"count":1,"total_count":1}}"#)
        let time = created.map { #","created_at":"\#($0)""# } ?? ""
        let item = #"{"value":"evil.example","description":"Pion, after the champion's approval: \#(reason)"\#(time)}"#
        service.answers["\(lists)/\(list)/items"] = (200, #"{"success":true,"errors":[],"result":[\#(item)],"result_info":{"page":1,"per_page":1000,"count":1,"total_count":1,"total_pages":1}}"#)
        let made = try await call("gateway-block", #"{"value":"evil.example","reason":"\#(reason)"}"#, service)
        XCTAssertFalse(made.isError, made.text)
        service.requests = []
        return service
    }

    /// Pion's record outlasts a relaunch and belongs to the connection that made it.
    func testTheRecordOutlastsARelaunchAndIsKeptPerConnection() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pion-cloudflare-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        Cloudflare.keepContainmentRecords(at: file)
        let service = FakeService()
        blocking(service)
        let made = try await call("block-ip", #"{"ip":"203.0.113.77","reason":"\#(reason)"}"#, service)
        XCTAssertFalse(made.isError, made.text)
        Cloudflare.keepContainmentRecords(at: nil)
        XCTAssertNil(try Cloudflare.owned(client(service)) { $0.id == ruleID })
        Cloudflare.keepContainmentRecords(at: file)
        XCTAssertNotNil(try Cloudflare.owned(client(service)) { $0.id == ruleID }, "read back after a relaunch")
        let other = try Cloudflare.containment.makeConnection(name: "Another", values: ["account": CloudflareTests.accountID])
        let refused = try await call("unblock", #"{"id":"\#(ruleID)"}"#, FakeService(), in: other)
        XCTAssertTrue(refused.isError && refused.text.contains("no record of making"), refused.text)
        Cloudflare.keepContainmentRecords(at: nil)
    }

    /// action-status and check-access only read; check-access says the edit permissions are verified only by the token's
    /// own record.
    func testActionStatusAndCheckAccessOnlyRead() async throws {
        let service = FakeService()
        service.answers[rules] = rulesPage(ruleJSON(notes: "someone else's"))
        let status = try await call("action-status", #"{"blocked":"203.0.113.77"}"#, service)
        XCTAssertTrue(!status.isError && status.text.contains("Pion has no record of making this one"), status.text)
        service.answers["\(account)/tokens/verify"] = envelope(#"{"id":"0123456789abcdef0123456789abcdef","status":"active"}"#)
        service.answers["\(account)/gateway/lists"] = (200, #"{"success":true,"errors":[],"result":[]}"#)
        service.answers["\(account)/devices/registrations"] = CloudflareTests.page("", total: 0)
        service.answers["\(account)/access/users"] = CloudflareTests.page("", total: 0)
        let checked = try await call("check-access", "{}", service)
        XCTAssertFalse(checked.isError, checked.text)
        XCTAssertTrue(checked.text.contains("✓ Cloudflare verified the token") && checked.text.contains("✓ The account's IP Access rules"), checked.text)
        XCTAssertTrue(checked.text.contains("Not verified: Account › Account Firewall Access Rules › Edit, Account › Zero Trust › Edit"), checked.text)
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" }, "only reads")
        service.answers["\(account)/tokens/0123456789abcdef0123456789abcdef"] = envelope(#"{"id":"0123456789abcdef0123456789abcdef","policies":[{"effect":"allow","permission_groups":[{"name":"Account Firewall Access Rules Write"},{"name":"Zero Trust Write"},{"name":"DNS Write"}]}]}"#)
        let proven = try await call("check-access", "{}", service)
        XCTAssertFalse(service.requests.contains { $0.url?.path.hasSuffix("/logs/audit") == true }, "check-access no longer reads the audit log")
        XCTAssertTrue(proven.text.contains("✓ Its own record shows Account › Account Firewall Access Rules › Edit and Account › Zero Trust › Edit") && proven.text.contains("⚠ It also holds DNS Write"), proven.text)
        XCTAssertFalse(proven.text.contains("Not verified"), proven.text)
    }
}
