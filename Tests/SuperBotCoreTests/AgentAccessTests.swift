import XCTest
@testable import SuperBotCore

final class AgentAccessTests: XCTestCase {
    func testNewAndExistingBotsDefaultToRestricted() {
        XCTAssertFalse(AgentAccessConfiguration().isExtended(UUID()))
    }

    func testOptInPersistsPerBotAndRevocationPersists() {
        let suite = "SuperBot.AccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bot = UUID(), other = UUID()
        var configuration = AgentAccessConfiguration.load(from: defaults)
        XCTAssertFalse(configuration.isExtended(bot))
        configuration.setExtended(true, for: bot)
        configuration.save(to: defaults)
        XCTAssertTrue(AgentAccessConfiguration.load(from: defaults).isExtended(bot))
        XCTAssertFalse(AgentAccessConfiguration.load(from: defaults).isExtended(other))
        configuration.setExtended(false, for: bot)
        configuration.save(to: defaults)
        XCTAssertFalse(AgentAccessConfiguration.load(from: defaults).isExtended(bot))
    }

    func testRequestIDsPreserveStringAndNumberIdentity() throws {
        let number = try XCTUnwrap(RuntimeRequestID(7))
        let string = try XCTUnwrap(RuntimeRequestID("7"))
        XCTAssertNotEqual(number, string)
        XCTAssertEqual(number.json as? Int, 7)
        XCTAssertEqual(string.json as? String, "7")
        XCTAssertNil(RuntimeRequestID(true))
        XCTAssertNil(RuntimeRequestID(nil))
    }

    func testCommandApprovalIsOneTimeOnly() {
        let request = approval("item/commandExecution/requestApproval", params: ["command": "touch /tmp/example"])
        XCTAssertEqual((request.response(allow: true)["result"] as? [String: String])?["decision"], "accept")
        XCTAssertEqual((request.response(allow: false)["result"] as? [String: String])?["decision"], "decline")
        XCTAssertTrue(request.detail.contains("touch /tmp/example"))
    }

    func testUnsupportedOfferedDecisionCannotBeInvented() {
        let request = approval("item/commandExecution/requestApproval", params: ["availableDecisions": ["decline", "cancel"]])
        XCTAssertFalse(request.canAllow)
        XCTAssertEqual((request.response(allow: true)["result"] as? [String: String])?["decision"], "decline")
    }

    func testPermissionScopeIsNeverSilentlyBroadenedOrPersisted() throws {
        let permissions: [String: Any] = ["fileSystem": ["read": ["/tmp/one-file"]], "network": ["enabled": true]]
        let request = approval("item/permissions/requestApproval", params: ["permissions": permissions])
        let result = try XCTUnwrap(request.response(allow: true)["result"] as? [String: Any])
        XCTAssertEqual(result["scope"] as? String, "turn")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: result["permissions"]!, options: .sortedKeys), try JSONSerialization.data(withJSONObject: permissions, options: .sortedKeys))
        let denied = request.response(allow: false)["result"] as! [String: Any]
        XCTAssertTrue((denied["permissions"] as! [String: Any]).isEmpty)
    }

    func testFullAccessDetailsAreVisible() {
        let request = approval("item/commandExecution/requestApproval", params: [
            "reason": "Needs access", "cwd": "/tmp/workspace", "stdin": "content",
            "additionalPermissions": ["fileSystem": ["write": ["/tmp/output"]]],
            "networkApprovalContext": ["host": "example.com", "protocol": "https"]
        ])
        for value in ["/tmp/workspace", "/tmp/output", "example.com", "https", "content"] {
            XCTAssertTrue(request.detail.contains(value))
        }
    }

    func testUserResponsesAreExplicitAndQuestionScoped() throws {
        let request = approval("item/tool/requestUserInput", params: ["questions": [["id": "q1", "question": "Proceed?"]]])
        let response = try XCTUnwrap(request.response(allow: true, answers: ["q1": "Yes", "invented": "Yes"])["result"] as? [String: Any])
        let answers = try XCTUnwrap(response["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers, ["q1": ["answers": ["Yes"]]])
        let skipped = request.response(allow: false, answers: ["q1": "Yes"])["result"] as! [String: Any]
        XCTAssertTrue((skipped["answers"] as! [String: Any]).isEmpty)
    }

    func testUnsupportedElicitationIsNotAcceptedWithFabricatedContent() {
        let request = approval("mcpServer/elicitation/request", params: ["mode": "url", "url": "https://example.com"])
        XCTAssertFalse(request.canAllow)
        XCTAssertEqual((request.response(allow: true)["result"] as? [String: Any])?["action"] as? String, "decline")
    }

    func testUnknownRequestFailsClosed() {
        let request = approval("future/permission/request", params: [:])
        XCTAssertFalse(request.canAllow)
        XCTAssertNotNil(request.response(allow: true)["error"])
    }

    func testPlainResponseIsNotAnApproval() {
        XCTAssertNil(AgentApprovalRequest(agentID: UUID(), message: ["id": 1, "result": [:]]))
    }

    private func approval(_ method: String, params: [String: Any]) -> AgentApprovalRequest {
        AgentApprovalRequest(agentID: UUID(), message: ["id": "request-1", "method": method, "params": params])!
    }
}
