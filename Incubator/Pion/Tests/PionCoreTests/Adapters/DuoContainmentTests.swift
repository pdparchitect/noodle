import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class DuoContainmentTests: XCTestCase {
    private let account = try! Duo.containment.makeConnection(name: "Duo Containment — Acme", values: ["host": "api-1a2b3c4d.duosecurity.com"])
    private let mallory = "DUMALLORY00000000001", phone = "DPATTACKER0000000001", token = "DHTOKEN0000000000001", key = "WAKEY000000000000001"

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await callTool(Duo.containmentAdapter, tool, arguments, on: service, in: account)
    }

    /// The changes a call sent: every request but a read.
    private func changes(_ service: FakeService) -> [String] {
        service.requests.filter { $0.httpMethod != "GET" }.map { "\($0.httpMethod!) \($0.url!.path)" }
    }

    private func body(_ request: URLRequest?) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: String]) ?? [:]
    }

    /// An account with Mallory, whose devices include one the attacker enrolled.
    private func service(status: String = "active", enrolled: Bool = true, devices: Bool = true) -> FakeService {
        let service = FakeService()
        let phones = devices ? #"[{"phone_id":"\#(phone)","number":"+15555550199","platform":"Google Android","type":"Mobile","capabilities":["push","sms"]}]"# : "[]"
        let tokens = devices ? #"[{"token_id":"\#(token)","type":"yk","serial":"0042"}]"# : "[]"
        let keys = devices ? #"[{"webauthnkey":"\#(key)","credential_name":"YubiKey"}]"# : "[]"
        let user = #"{"user_id":"\#(mallory)","username":"mallory","email":"mallory@acme.example","status":"\#(status)","is_enrolled":\#(enrolled),"phones":\#(phones),"tokens":\#(tokens),"webauthncredentials":\#(keys),"aliases":{"alias1":"m.allory"}}"#
        service.answers["/admin/v1/users/\(mallory)"] = (200, #"{"stat":"OK","response":\#(user)}"#)
        service.answers["/admin/v1/users?username=mallory"] = (200, #"{"stat":"OK","response":[\#(user)]}"#)
        service.answers["/admin/v1/users?username=m.allory"] = (200, #"{"stat":"OK","response":[\#(user)]}"#)
        for path in ["/admin/v1/users/\(mallory)/phones/\(phone)", "/admin/v1/users/\(mallory)/tokens/\(token)", "/admin/v1/webauthncredentials/\(key)",
                     "/admin/v1/users/enroll", "/admin/v1/phones/\(phone)/send_sms_activation", "/admin/v1/bypass_codes/DB0000000000000000A1",
                     "/admin/v1/bypass_codes/DB0000000000000000A2"] {
            service.answers[path] = (200, #"{"stat":"OK","response":""}"#)
        }
        return service
    }

    func testContainmentIsItsOwnToolWithKeysOfItsOwn() throws {
        XCTAssertEqual(Duo.containment.name, "Duo Containment")
        XCTAssertNotEqual(Duo.containment.id, Duo.preset.id)
        XCTAssertNotNil(UUID(uuidString: Duo.containment.id))
        XCTAssertEqual(Duo.containment.adapter, "duo-containment")
        XCTAssertNotNil(PionAdapters.all["duo-containment"])
        XCTAssertNil(Duo.containmentAdapter.watchedTool)
        XCTAssertTrue(PionCatalogue.entries.contains { $0.id == Duo.containment.id })
        guard case .connection(let configuration) = Duo.containment.configuration else { return XCTFail() }
        XCTAssertEqual(configuration.composedToken?.format, .duoSignature)
        let steps = Duo.containmentSetup.joined(separator: " ")
        XCTAssertTrue(steps.contains("Grant resource - Read") && steps.contains("Grant resource - Write") && steps.contains("apart from Duo Detection"), steps)
    }

    /// Every change cuts off or restores access, or removes something, so each waits for approval and says how to recover.
    func testEveryChangeIsHeldForApprovalAndSaysHowToRecover() async throws {
        let listed = try JSONSerialization.jsonObject(with: try await Duo.containmentAdapter.tools(for: account)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        let reads: Set<String> = ["user", "check-access"]
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
            if reads.contains(name) {
                XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true, name)
            } else {
                XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false, name)
                XCTAssertEqual(annotations["destructiveHint"] as? Bool, true, name)
                XCTAssertTrue((tool["description"] as? String)?.contains("Recovery:") == true, name)
            }
        }
        XCTAssertEqual(tools.count, 11)
    }

    func testDisableUserSetsTheirStatusWithASignedJSONBody() async throws {
        let service = service()
        let result = try await call("disable-user", #"{"user":"mallory"}"#, service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(changes(service), ["POST /admin/v1/users/\(mallory)"])
        let change = service.requests.last
        XCTAssertEqual(body(change), ["status": "disabled"])
        XCTAssertEqual(change?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(result.text.contains("✓ Disable mallory (\(mallory)), who was active"), result.text)
        XCTAssertTrue(result.text.contains("enable-user sets them active again"), result.text)
        XCTAssertTrue(result.text.contains("does not end sessions"), result.text)

        let again = try await call("disable-user", #"{"user":"mallory"}"#, self.service(status: "disabled"))
        XCTAssertTrue(again.isError)
        XCTAssertTrue(again.text.contains("already disabled"), again.text)
    }

    func testEnableAndClearBypassActOnlyOnTheStatusTheyUndo() async throws {
        let locked = service(status: "locked out")
        let enabled = try await call("enable-user", #"{"user":"\#(mallory)"}"#, locked)
        XCTAssertFalse(enabled.isError, enabled.text)
        XCTAssertEqual(body(locked.requests.last), ["status": "active"])

        let bypassed = service(status: "bypass")
        let refused = try await call("enable-user", #"{"user":"mallory"}"#, bypassed)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("clear-bypass"), refused.text)
        let cleared = try await call("clear-bypass", #"{"user":"mallory"}"#, bypassed)
        XCTAssertFalse(cleared.isError, cleared.text)
        XCTAssertEqual(body(bypassed.requests.last), ["status": "active"])
        XCTAssertEqual(changes(bypassed), ["POST /admin/v1/users/\(mallory)"])
    }

    func testAnAliasIsNeverActedOn() async throws {
        let service = service()
        let result = try await call("disable-user", #"{"user":"m.allory"}"#, service)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("is an alias of mallory"), result.text)
        XCTAssertTrue(changes(service).isEmpty)
    }

    func testADirectorySyncedUserIsRefusedPlainly() async throws {
        let service = service()
        // The user is read, then the change refused.
        let path = "/admin/v1/users/\(mallory)"
        service.sequences[path] = [service.answers[path]!, (400, #"{"stat":"FAIL","code":40010,"message":"User is managed by directory sync. Some attributes are read-only."}"#)]
        let result = try await call("disable-user", #"{"user":"\#(mallory)"}"#, service)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.hasPrefix("Nothing was changed."), result.text)
        XCTAssertTrue(result.text.contains("a directory sync or SCIM manages this user"), result.text)
    }

    func testDeleteBypassCodesDeletesEachByItsIDAndNeverShowsThem() async throws {
        let service = service()
        service.answers["/admin/v1/users/\(mallory)/bypass_codes"] = (200, #"{"stat":"OK","response":[{"bypass_code_id":"DB0000000000000000A1","created":1700000000,"code":"271828182"},{"bypass_code_id":"DB0000000000000000A2","created":1700000100}]}"#)
        let result = try await call("delete-bypass-codes", #"{"user":"mallory"}"#, service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(changes(service), ["DELETE /admin/v1/bypass_codes/DB0000000000000000A1", "DELETE /admin/v1/bypass_codes/DB0000000000000000A2"])
        XCTAssertFalse(result.text.contains("271828182"), "a bypass code was shown")
        XCTAssertTrue(result.text.contains("bypass code 2 of 2 of mallory"), result.text)

        let none = self.service()
        none.answers["/admin/v1/users/\(mallory)/bypass_codes"] = (200, #"{"stat":"OK","response":[]}"#)
        let nothing = try await call("delete-bypass-codes", #"{"user":"mallory"}"#, none)
        XCTAssertTrue(nothing.isError)
        XCTAssertTrue(nothing.text.contains("holds no bypass codes"), nothing.text)
    }

    func testDevicesAreRemovedOnlyFromTheUserWhoHasThem() async throws {
        let service = service()
        let phoneResult = try await call("remove-phone", #"{"user":"mallory","phone":"\#(phone)"}"#, service)
        XCTAssertFalse(phoneResult.isError, phoneResult.text)
        let tokenResult = try await call("remove-token", #"{"user":"mallory","token":"\#(token)"}"#, service)
        XCTAssertFalse(tokenResult.isError, tokenResult.text)
        let keyResult = try await call("remove-security-key", #"{"user":"mallory","key":"\#(key)"}"#, service)
        XCTAssertFalse(keyResult.isError, keyResult.text)
        XCTAssertEqual(changes(service), ["DELETE /admin/v1/users/\(mallory)/phones/\(phone)", "DELETE /admin/v1/users/\(mallory)/tokens/\(token)",
                                          "DELETE /admin/v1/webauthncredentials/\(key)"])

        let other = self.service()
        let notTheirs = try await call("remove-phone", #"{"user":"mallory","phone":"DPSOMEONEELSE0000001"}"#, other)
        XCTAssertTrue(notTheirs.isError)
        XCTAssertTrue(notTheirs.text.contains("has no phone DPSOMEONEELSE0000001"), notTheirs.text)
        let malformed = try await call("remove-security-key", #"{"user":"mallory","key":"../admins"}"#, other)
        XCTAssertTrue(malformed.isError)
        XCTAssertTrue(changes(other).isEmpty)
    }

    func testEnrollmentGoesOnlyToAUserWithNoDevicesAndActivationOnlyToTheirMobile() async throws {
        let enrolled = service()
        let refused = try await call("send-enrollment", #"{"user":"mallory"}"#, enrolled)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("still enrolled"), refused.text)

        let bare = service(enrolled: false, devices: false)
        let sent = try await call("send-enrollment", #"{"user":"mallory","validHours":2}"#, bare)
        XCTAssertFalse(sent.isError, sent.text)
        XCTAssertEqual(changes(bare), ["POST /admin/v1/users/enroll"])
        XCTAssertEqual(body(bare.requests.last), ["username": "mallory", "email": "mallory@acme.example", "valid_secs": "7200"])

        let activation = service()
        let texted = try await call("send-activation", #"{"user":"mallory","phone":"\#(phone)"}"#, activation)
        XCTAssertFalse(texted.isError, texted.text)
        XCTAssertEqual(changes(activation), ["POST /admin/v1/phones/\(phone)/send_sms_activation"])
    }

    func testCheckAccessProbesWriteWithAChangeDuoCanOnlyRefuse() async throws {
        let allowed = FakeService()
        allowed.answers["/admin/v1/users"] = (200, #"{"stat":"OK","response":[]}"#)
        allowed.answers["/admin/v1/users/\(Duo.ContainmentCheckAccess.nobody)"] = (404, #"{"stat":"FAIL","code":40401,"message":"Resource not found"}"#)
        let yes = try await call("check-access", "{}", allowed)
        XCTAssertTrue(yes.text.contains("✓ Changes to users and devices (Grant resource - Write)"), yes.text)
        XCTAssertEqual(body(allowed.requests.last), [:])

        let denied = FakeService()
        denied.answers["/admin/v1/users"] = (200, #"{"stat":"OK","response":[]}"#)
        denied.answers["/admin/v1/users/\(Duo.ContainmentCheckAccess.nobody)"] = (403, #"{"stat":"FAIL","code":40301,"message":"Access forbidden"}"#)
        let no = try await call("check-access", "{}", denied)
        XCTAssertTrue(no.text.contains("✗ Changes to users and devices: the Admin API application lacks Grant resource - Write"), no.text)
    }
}
