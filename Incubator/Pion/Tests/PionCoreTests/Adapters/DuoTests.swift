import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class DuoTests: XCTestCase {
    private let account = try! Duo.preset.makeConnection(name: "Duo Detection — Acme", values: ["host": "api-1a2b3c4d.duosecurity.com"])
    private let alice = "DUALICE0000000000001", bob = "DUBOB00000000000001X", carol = "DUCAROL0000000000001"

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await callTool(Duo.adapter, tool, arguments, on: service, in: account)
    }

    private func call(_ tool: String, _ service: FakeService) async throws -> AdapterResult {
        try await call(tool, "{}", service)
    }

    private static func ok(_ response: String, metadata: String? = nil) -> (Int, String) {
        (200, #"{"stat":"OK","response":\#(response)\#(metadata.map { #","metadata":\#($0)"# } ?? "")}"#)
    }

    private static let forbidden = (403, #"{"stat":"FAIL","code":40301,"message":"Access forbidden"}"#)
    private var recent: Int { Int(Date().timeIntervalSince1970) - 600 }

    func testDetectionSignsEachRequestWithKeysKeptInKeychainAndOnlyReads() throws {
        XCTAssertEqual(Duo.preset.name, "Duo Detection")
        XCTAssertNotNil(UUID(uuidString: Duo.preset.id))
        XCTAssertEqual(Duo.preset.adapter, "duo")
        XCTAssertNotNil(PionAdapters.all["duo"])
        XCTAssertEqual(Duo.adapter.watchedTool, "security-events")
        guard case .connection(let configuration) = Duo.preset.configuration else { return XCTFail() }
        XCTAssertEqual(configuration.composedToken?.format, .duoSignature)
        XCTAssertEqual(configuration.composedToken?.first, "Integration key")
        XCTAssertEqual(configuration.composedToken?.second, "Secret key")
        XCTAssertNil(configuration.oauth)
        XCTAssertEqual(account.endpoint.absoluteString, "https://api-1a2b3c4d.duosecurity.com")
        XCTAssertEqual(account.tokenHeader, "Authorization")
        XCTAssertNil(account.tokenScheme)
        XCTAssertEqual(try Duo.keys.compose("DIWJ8X6AEYOR5OMC6TQ1", "Zh5eGmUq9zpfQnyUIu5OL9iWoMMv5ZNmk3zLJ4Ep"), ComposedToken.duoSignaturePrefix + "DIWJ8X6AEYOR5OMC6TQ1:Zh5eGmUq9zpfQnyUIu5OL9iWoMMv5ZNmk3zLJ4Ep")
        let steps = Duo.setup.joined(separator: " ")
        for words in ["Owner", "Admin API", "Grant read log", "Grant resource - Read", "Leave every write permission off", "no OAuth", "Keychain", "API hostname"] {
            XCTAssertTrue(steps.contains(words), words)
        }
        XCTAssertFalse(steps.contains("tick only **Grant resource - Write"))
        XCTAssertTrue(Duo.containmentSetup.joined().contains("**Grant resource - Write**"))
        // Every read the Detection tool offers only reads.
        for operation in Duo.operations where ToolJob.detection.offers(type(of: operation).jobs) {
            XCTAssertTrue(type(of: operation).readOnly, type(of: operation).name)
        }
    }

    func testAHostThatIsNotDuosIsNeverSent() async throws {
        let elsewhere = try Duo.preset.makeConnection(name: "Duo", values: ["host": "api-1a2b3c4d.duosecurity.com.evil.example"])
        let service = FakeService()
        let result = try await callTool(Duo.adapter, "users", "{}", on: service, in: elsewhere)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("not one of Duo's"), result.text)
        XCTAssertTrue(service.requests.isEmpty, "a request went to a host that is not Duo's")
        XCTAssertTrue(Duo.isDuoHost("api-1a2b3c4d.duofederal.com"))
        XCTAssertFalse(Duo.isDuoHost("1a2b3c4d.duosecurity.com"))
    }

    func testUsersPageByNextOffsetAndLeadWithBypassUnenrolledAndLockedOut() async throws {
        let service = FakeService()
        service.sequences["/admin/v1/users"] = [
            Self.ok(#"[{"user_id":"\#(alice)","username":"alice","status":"active","is_enrolled":true,"last_login":\#(recent),"phones":[{"phone_id":"DPALICE0000000000001"}]},{"user_id":"\#(bob)","username":"bob","status":"bypass","is_enrolled":true,"last_login":null}]"#,
                    metadata: #"{"next_offset":300,"total_objects":3}"#),
            Self.ok(#"[{"user_id":"\#(carol)","username":"carol","status":"locked out","lockout_reason":"Failed Attempts","is_enrolled":false}]"#),
        ]
        let result = try await call("users", service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(service.requests.map { queryItems($0)["offset"] }, ["0", "300"])
        XCTAssertEqual(service.requests.map { queryItems($0)["limit"] }, ["300", "300"])
        XCTAssertTrue(result.text.contains("3 users"), result.text)
        let bypass = try XCTUnwrap(result.text.range(of: "In bypass status")), unenrolled = try XCTUnwrap(result.text.range(of: "Not enrolled"))
        XCTAssertLessThan(bypass.lowerBound, unenrolled.lowerBound)
        XCTAssertTrue(result.text.contains("locked out for Failed Attempts"), result.text)
        XCTAssertEqual(result.structured?["bypass"] as? [String], [bob])
        XCTAssertEqual(result.structured?["complete"] as? Bool, true)
    }

    func testARefusalNamesThePermissionToTick() async throws {
        let service = FakeService()
        service.answers["/admin/v1/settings"] = Self.forbidden
        let settings = try await call("settings", service)
        XCTAssertTrue(settings.isError)
        XCTAssertTrue(settings.text.contains("Grant settings"), settings.text)
        XCTAssertTrue(settings.text.contains("no read-only form"), settings.text)
        XCTAssertTrue(settings.text.contains("40301: Access forbidden"), settings.text)

        service.answers["/admin/v1/admins"] = Self.forbidden
        let admins = try await call("admins", service)
        XCTAssertTrue(admins.text.contains("Grant administrators - Read"), admins.text)

        service.answers["/admin/v1/phones"] = (401, #"{"stat":"FAIL","code":40103,"message":"Invalid signature in request credentials"}"#)
        let phones = try await call("phones", service)
        XCTAssertTrue(phones.text.contains("did not accept the request's signature"), phones.text)
        XCTAssertTrue(phones.text.contains("clock"), phones.text)
    }

    func testBypassCodesAreCountedAndDatedButNeverShown() async throws {
        let service = FakeService()
        let old = recent - 200 * 86_400
        // A code Duo might one day include is never kept or shown.
        service.answers["/admin/v1/bypass_codes"] = Self.ok(#"[{"bypass_code_id":"DB0000000000000000A1","admin_email":"helpdesk@acme.example","created":\#(old),"expiration":null,"reuse_count":null,"code":"314159265","user":{"user_id":"\#(bob)","username":"bob"}},{"bypass_code_id":"DB0000000000000000A2","created":\#(recent),"expiration":\#(recent + 3_600),"reuse_count":1,"user":{"user_id":"\#(alice)","username":"alice"}}]"#)
        let result = try await call("bypass-codes", service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("2 bypass codes held by 2 users: 1 never expire, 1 can be used without limit, 1 are over 90 days old"), result.text)
        XCTAssertTrue(result.text.hasPrefix("2 bypass codes") && result.text.contains("bob: 1 bypass code"), result.text)
        let everything = result.text + String(data: try JSONSerialization.data(withJSONObject: result.structured ?? [:]), encoding: .utf8)!
        XCTAssertFalse(everything.contains("314159265"), "a bypass code was shown")
        XCTAssertTrue(result.text.contains("never shows the codes"), result.text)
    }

    func testAuthLogsFilterByUserAndResultAndGiveTheOffsetToReadOn() async throws {
        let service = FakeService()
        service.answers["/admin/v1/users?username=alice"] = Self.ok(#"[{"user_id":"\#(alice)","username":"alice","status":"active"}]"#)
        service.answers["/admin/v2/logs/authentication"] = Self.ok(#"{"authlogs":[{"txid":"7a1c-0001","timestamp":\#(recent),"result":"denied","reason":"location_restricted","factor":"duo_push","user":{"key":"\#(alice)","name":"alice"},"application":{"key":"DIAPP000000000000001","name":"VPN"},"access_device":{"ip":"198.51.100.7","os":"Windows","os_version":"11","browser":"Chrome","location":{"city":"Lagos","country":"Nigeria"}},"auth_device":{"name":"iPhone","ip":"203.0.113.9"}}],"metadata":{"next_offset":["1700000000000","7a1c-0001"],"total_objects":5}}"#)
        let result = try await call("auth-logs", #"{"user":"alice","result":"denied","limit":1}"#, service)
        XCTAssertFalse(result.isError, result.text)
        let request = try XCTUnwrap(service.requests.last)
        XCTAssertEqual(request.url?.path, "/admin/v2/logs/authentication")
        let query = queryItems(request)
        XCTAssertEqual(query["users"], alice)
        XCTAssertEqual(query["results"], "denied")
        XCTAssertEqual(query["sort"], "ts:desc")
        XCTAssertEqual(query["mintime"]?.count, 13, "mintime is in milliseconds")
        XCTAssertTrue(result.text.contains("denied (location_restricted) alice by duo_push to VPN from 198.51.100.7 (Lagos, Nigeria), Windows 11, Chrome; approved on iPhone"), result.text)
        XCTAssertTrue(result.text.contains("nextOffset 1700000000000,7a1c-0001"), result.text)

        _ = try await call("auth-logs", #"{"nextOffset":"1700000000000,7a1c-0001"}"#, service)
        XCTAssertEqual(queryItems(service.requests.last)["next_offset"], "1700000000000,7a1c-0001")
        let bad = try await call("auth-logs", #"{"nextOffset":"1700000000000&users=DUX"}"#, service)
        XCTAssertTrue(bad.isError)
    }

    func testUserShowsDevicesWithTheirIDsAndCountsBypassCodes() async throws {
        let service = FakeService()
        service.answers["/admin/v1/users/\(alice)"] = Self.ok(#"{"user_id":"\#(alice)","username":"alice","realname":"Alice Ng","email":"alice@acme.example","status":"active","is_enrolled":true,"last_login":\#(recent),"phones":[{"phone_id":"DPALICE0000000000001","number":"+15555550100","platform":"Apple iOS","capabilities":["push","sms"],"tampered":"Tampered","encrypted":"Encrypted","screenlock":"Locked","activated":true}],"tokens":[{"token_id":"DHTOKEN0000000000001","type":"yk","serial":"0042"}],"webauthncredentials":[{"webauthnkey":"WAKEY000000000000001","credential_name":"YubiKey","label":"Security Key"}],"groups":[{"name":"Contractors","status":"Bypass"}]}"#)
        service.answers["/admin/v1/users/\(alice)/bypass_codes"] = Self.ok(#"[{"bypass_code_id":"DB01","created":\#(recent),"expiration":null,"reuse_count":null,"admin_email":"helpdesk@acme.example"}]"#)
        let result = try await call("user", #"{"user":"\#(alice)"}"#, service)
        XCTAssertFalse(result.isError, result.text)
        for words in ["[DPALICE0000000000001]", "jailbroken or rooted", "[DHTOKEN0000000000001]", "[WAKEY000000000000001]", "Contractors (Bypass)",
                      "1 bypass code", "1 never expires", "by helpdesk@acme.example"] {
            XCTAssertTrue(result.text.contains(words), words + " in " + result.text)
        }
        XCTAssertEqual(result.structured?["bypassCodes"] as? Int, 1)
    }

    func testAdminsPutOwnersFirstAndFlagThoseWithoutAHardwareTokenOrSecurityKey() async throws {
        let service = FakeService()
        service.answers["/admin/v1/admins"] = Self.ok(#"[{"admin_id":"DE01","name":"Help Desk","email":"help@acme.example","role":"Help Desk","status":"Active","last_login":\#(recent)},{"admin_id":"DE02","name":"Owner One","email":"owner@acme.example","role":"Owner","status":"Active","last_login":\#(recent),"webauthncredentials":[{"webauthnkey":"WAOWNER0000000000001"}]}]"#)
        let result = try await call("admins", service)
        XCTAssertFalse(result.isError, result.text)
        let owner = try XCTUnwrap(result.text.range(of: "Owner One")), help = try XCTUnwrap(result.text.range(of: "Help Desk <"))
        XCTAssertLessThan(owner.lowerBound, help.lowerBound)
        XCTAssertTrue(result.text.contains("1 active administrator has no hardware token or security key"), result.text)
        XCTAssertEqual(result.structured?["withoutStrongFactor"] as? [String], ["help@acme.example"])
    }

    func testIntegrationsLeadWithAdminAPIApplicationsThatCanChangeDuoAndNeverShowSecretKeys() async throws {
        let service = FakeService()
        service.answers["/admin/v3/integrations"] = Self.ok(#"[{"integration_key":"DIVPN000000000000001","name":"VPN","type":"radius","user_access":"ALL_USERS","secret_key":"************abcd"},{"integration_key":"DIAPI000000000000001","name":"Old sync script","type":"adminapi","adminapi_write_resource":1,"adminapi_read_resource":1,"adminapi_integrations":0,"networks_for_api_access":"","secret_key":"************wxyz"}]"#)
        let result = try await call("integrations", service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Admin API applications that can change Duo (1): Old sync script (adminapi)"), result.text)
        XCTAssertTrue(result.text.contains("Grant resource - Write"), result.text)
        XCTAssertTrue(result.text.contains("from any network"), result.text)
        XCTAssertTrue(result.text.contains("let every user in under the global policy alone"), result.text)
        let everything = result.text + String(data: try JSONSerialization.data(withJSONObject: result.structured ?? [:]), encoding: .utf8)!
        XCTAssertFalse(everything.contains("abcd") || everything.contains("wxyz"), "part of a secret key was shown")
    }

    func testPhonesLeadWithTamperedAndUnprotectedDevices() async throws {
        let service = FakeService()
        service.answers["/admin/v1/phones"] = Self.ok(#"[{"phone_id":"DPGOOD00000000000001","platform":"Apple iOS","capabilities":["push"],"tampered":"Not tampered","encrypted":"Encrypted","screenlock":"Locked","fingerprint":"Configured","activated":true},{"phone_id":"DPBAD000000000000001","platform":"Google Android","capabilities":["push","sms"],"tampered":"Tampered","encrypted":"Unencrypted","screenlock":"Unlocked","activated":true,"users":[{"username":"bob"}]},{"phone_id":"DPDESK00000000000001","platform":"Unknown","type":"landline","capabilities":["phone"]}]"#)
        let result = try await call("phones", service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("jailbroken or rooted, unencrypted, no screen lock [DPBAD000000000000001], used by bob"), result.text)
        XCTAssertTrue(result.text.contains("1 phone can only take calls or SMS"), result.text)
        XCTAssertEqual(result.structured?["concerning"] as? [String], ["DPBAD000000000000001"])
    }

    func testSettingsLeadWithTheirGaps() async throws {
        let service = FakeService()
        service.answers["/admin/v1/settings"] = Self.ok(#"{"name":"Acme","lockout_threshold":20,"lockout_expire_duration":15,"fraud_email_enabled":false,"helpdesk_bypass":"allow","helpdesk_bypass_expiration":null,"user_managers_can_put_users_in_bypass":true,"email_activity_notification_enabled":false,"push_activity_notification_enabled":false,"unenrolled_user_lockout_threshold":0,"inactive_user_expiration":0,"inactive_admin_expiration":0,"minimum_password_length":8}"#)
        let result = try await call("settings", service)
        XCTAssertFalse(result.isError, result.text)
        for words in ["locked out only after 20 failed attempts", "unlocked by itself after 15 minutes", "fraud_email_enabled off", "Help Desk administrators may make bypass codes",
                      "User Manager administrators may put users in bypass status", "not told when a device is added", "never enroll are never locked out", "need only 8 characters"] {
            XCTAssertTrue(result.text.contains(words), words)
        }
    }

    func testPoliciesLeadWithWhatTheyLetThroughAndSayPlainlyWhenTheAPIIsMissing() async throws {
        let service = FakeService()
        service.answers["/admin/v2/policies/global"] = Self.ok(#"{"policy_key":"global","policy_name":"Global Policy","is_global_policy":true,"sections":{"authentication_methods":{"allowed_auth_list":["duo-push","sms"],"blocked_auth_list":["phonecall","bypass"],"require_verified_push":false},"new_user":{"new_user_behavior":"no-mfa"},"authorized_networks":{"no_2fa_required":{"ip_list":["203.0.113.0/24"]}},"remembered_devices":{"browser_apps":{"enabled":true,"remember_method":"user-based","user_based":{"max_time_units":"days","max_time_value":30}}}}}"#)
        service.answers["/admin/v2/policies"] = Self.ok(#"[{"policy_key":"global","policy_name":"Global Policy","is_global_policy":true,"sections":{}},{"policy_key":"POVPN000000000000001","policy_name":"VPN","is_global_policy":false,"sections":{"authentication_policy":{"user_auth_behavior":"bypass"}}}]"#)
        service.answers["/admin/v2/policies/summary"] = Self.ok(#"{"policies":[{"policy_key":"POVPN000000000000001","policy_name":"VPN","policy_applies_to":[{"app_name":"Cisco VPN","apply_type":"app"}]}]}"#)
        let result = try await call("policies", service)
        XCTAssertFalse(result.isError, result.text)
        for words in ["allows SMS passcodes", "without Verified Push", "new user policy no-mfa", "203.0.113.0/24", "remembers browsers for 30 days",
                      "VPN [POVPN000000000000001], on Cisco VPN: skips the second factor for everyone"] {
            XCTAssertTrue(result.text.contains(words), words + " in " + result.text)
        }
        XCTAssertFalse(result.text.contains("phone calls"), "phone calls are blocked")
        XCTAssertFalse(result.text.contains("accepts bypass codes"), "bypass codes are blocked")

        let missing = FakeService()
        let refused = try await callTool(Duo.adapter, "policies", "{}", on: missing, in: account)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("no Policies API"), refused.text)
    }

    func testSecurityEventsJudgeEachFeedAndSayWhatWasNotRead() async throws {
        let service = FakeService()
        service.answers["/admin/v2/logs/authentication"] = Self.ok(#"{"authlogs":[{"txid":"fraud-1","timestamp":\#(recent),"result":"fraud","reason":"user_marked_fraud","user":{"name":"alice"},"access_device":{"ip":"198.51.100.7"}}],"metadata":{}}"#)
        service.answers["/admin/v1/logs/administrator"] = Self.ok(#"[{"action":"bypass_create","object":"bob","username":"Help Desk","timestamp":\#(recent)},{"action":"user_update","object":"carol","username":"Owner One","timestamp":\#(recent),"description":"{\"status\": \"Bypass\"}"},{"action":"integration_skey_view","object":"Old sync script","username":"Owner One","timestamp":\#(recent)},{"action":"admin_login","username":"Owner One","timestamp":\#(recent)},{"action":"user_update","object":"dave","username":"Owner One","timestamp":\#(recent),"description":"{\"notes\": \"new laptop\"}"}]"#)
        service.answers["/admin/v1/trust_monitor/events"] = Self.forbidden
        let result = try await call("security-events", service)
        XCTAssertFalse(result.isError, result.text)
        for words in ["alice reported a login attempt from 198.51.100.7 as fraud", "bypass code created for bob", "carol set to bypass status",
                      "secret key of the application Old sync script was viewed", "edition most likely lacks it"] {
            XCTAssertTrue(result.text.contains(words), words + " in " + result.text)
        }
        XCTAssertFalse(result.text.contains("admin_login") || result.text.contains("dave"), result.text)
        XCTAssertEqual((result.structured?["events"] as? [[String: Any]])?.count, 4)
        let reasons = service.requests.first { $0.url?.path == "/admin/v2/logs/authentication" }.flatMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "reasons" }.compactMap(\.value)
        }
        XCTAssertEqual(reasons.map(Set.init), Set(Duo.watchedReasons))
    }

    func testTheWatchTellsEachEventOnceAndAnUnreadableFeedOnceWhileItLasts() async throws {
        let service = FakeService()
        service.answers["/admin/v2/logs/authentication"] = Self.ok(#"{"authlogs":[{"txid":"fraud-1","timestamp":\#(recent),"result":"fraud","reason":"user_marked_fraud","user":{"name":"alice"}}]}"#)
        service.answers["/admin/v1/logs/administrator"] = Self.forbidden
        service.answers["/admin/v1/trust_monitor/events"] = Self.ok(#"{"events":[]}"#)
        let trigger = Duo.NewSecurityEvents()
        let client = ServiceClient(base: account.endpoint, access: service, settings: account.settings ?? [:], account: account.id)
        let since = Date().addingTimeInterval(-3_600)
        let first = try await trigger.alerts(since: since, on: client, account: account.id)
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first.contains { $0.id == "auth/fraud-1" })
        XCTAssertTrue(first.contains { $0.id.hasPrefix("unreadable/administrator-log/") })
        let second = try await trigger.alerts(since: since, on: client, account: account.id)
        XCTAssertTrue(second.isEmpty, "\(second)")

        // Duo rate limiting holds the watch back rather than dropping what it could not read.
        service.answers["/admin/v1/logs/administrator"] = (429, #"{"stat":"FAIL","code":42901,"message":"Too Many Requests"}"#)
        do { _ = try await trigger.alerts(since: since, on: client, account: account.id); XCTFail("a rate-limited read was taken as read") } catch {}
    }

    func testCheckAccessSaysWhichPermissionToTickForEachRead() async throws {
        let service = FakeService()
        service.answers["/admin/v2/logs/authentication"] = Self.ok(#"{"authlogs":[]}"#)
        service.answers["/admin/v1/users"] = Self.ok("[]")
        service.answers["/admin/v1/admins"] = Self.forbidden
        service.answers["/admin/v1/settings"] = Self.forbidden
        service.answers["/admin/v1/trust_monitor/events"] = Self.forbidden
        service.answers["/admin/v1/info/summary"] = Self.ok(#"{"edition":"Duo Essentials","user_count":42,"admin_count":3,"integration_count":7}"#)
        service.answers["/admin/v3/integrations"] = Self.ok(#"[{"name":"Pion Detection","type":"adminapi","adminapi_read_log":1,"adminapi_read_resource":1},{"name":"Old sync script","type":"adminapi","adminapi_write_resource":1}]"#)
        let result = try await call("check-access", service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("✓ Logs (Grant read log)"), result.text)
        XCTAssertTrue(result.text.contains("✓ Users, phones, policies and applications (Grant resource - Read)"), result.text)
        XCTAssertTrue(result.text.contains("✗ Administrators: the Admin API application lacks Grant administrators - Read"), result.text)
        XCTAssertTrue(result.text.contains("✗ Global settings: the Admin API application lacks Grant settings"), result.text)
        XCTAssertTrue(result.text.contains("most likely lacks Trust Monitor"), result.text)
        XCTAssertTrue(result.text.contains("Duo Essentials, 42 users"), result.text)
        XCTAssertTrue(result.text.contains("Admin API applications that can change Duo: Old sync script (Grant resource - Write)"), result.text)
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" }, "check-access changed something")
    }
}
