import XCTest
@testable import NoodleCore

final class AgentAccessTests: XCTestCase {
    func testNewAndExistingBotsDefaultToAutonomousAccess() {
        XCTAssertTrue(AgentAccessConfiguration().isExtended(UUID()))
    }

    func testRestrictionPersistsPerBotAndCanBeRemoved() {
        let suite = "Noodle.AccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bot = UUID(), other = UUID()
        var configuration = AgentAccessConfiguration.load(from: defaults)
        XCTAssertTrue(configuration.isExtended(bot))
        configuration.setExtended(false, for: bot)
        configuration.save(to: defaults)
        XCTAssertFalse(AgentAccessConfiguration.load(from: defaults).isExtended(bot))
        XCTAssertTrue(AgentAccessConfiguration.load(from: defaults).isExtended(other))
        configuration.setExtended(true, for: bot)
        configuration.save(to: defaults)
        XCTAssertTrue(AgentAccessConfiguration.load(from: defaults).isExtended(bot))
    }

    func testLegacyOptInStorageMigratesToAutonomousDefaults() {
        let suite = "Noodle.AccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previouslyExtendedBot = UUID()
        let previouslyRestrictedBot = UUID()
        defaults.set([previouslyExtendedBot.uuidString], forKey: "Noodle.access.extendedAgents")

        let configuration = AgentAccessConfiguration.load(from: defaults)
        XCTAssertTrue(configuration.isExtended(previouslyExtendedBot))
        XCTAssertTrue(configuration.isExtended(previouslyRestrictedBot))
        configuration.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: "Noodle.access.extendedAgents"))
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

    func testEmptyToolConfirmationRequiresExplicitAllowAndReturnsEmptyContent() throws {
        let request = approval("mcpServer/elicitation/request", params: [
            "mode": "form", "message": "Allow Browser use to access https://www.google.com?",
            "serverName": "cua_repl", "requestedSchema": ["type": "object", "properties": [String: Any]()]
        ])
        XCTAssertTrue(request.canAllow)
        let declined = request.response(allow: false)["result"] as! [String: Any]
        XCTAssertEqual(declined["action"] as? String, "decline")
        let accepted = request.response(allow: true)["result"] as! [String: Any]
        XCTAssertEqual(accepted["action"] as? String, "accept")
        XCTAssertTrue(try XCTUnwrap(accepted["content"] as? [String: Any]).isEmpty)
        XCTAssertTrue(request.detail.contains("https://www.google.com"))
    }

    func testRoutineToolConfirmationIsAutomaticallyAccepted() throws {
        let request = approval("mcpServer/elicitation/request", params: [
            "mode": "form", "message": "Allow Browser use?",
            "requestedSchema": ["type": "object", "properties": [String: Any]()]
        ])
        let response = try XCTUnwrap(request.automaticResponse(extendedAccess: true))
        XCTAssertEqual((response["result"] as? [String: Any])?["action"] as? String, "accept")
    }

    func testAutonomousAccessAutomaticallyAllowsRuntimePermissions() {
        for method in [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval"
        ] {
            let request = approval(method, params: ["permissions": ["network": ["enabled": true]]])
            let response = request.automaticResponse(extendedAccess: true)
            XCTAssertNotNil(response)
            if method == "item/permissions/requestApproval" {
                let permissions = (response?["result"] as? [String: Any])?["permissions"] as? [String: Any]
                XCTAssertFalse(permissions?.isEmpty ?? true)
            } else {
                XCTAssertEqual((response?["result"] as? [String: String])?["decision"], "accept")
            }
        }
    }

    func testRestrictedAccessAutomaticallyDeclinesRuntimePermissions() {
        let request = approval("item/commandExecution/requestApproval", params: ["command": "open example"])
        let response = request.automaticResponse(extendedAccess: false)
        XCTAssertEqual((response?["result"] as? [String: String])?["decision"], "decline")
    }

    func testOnlyQuestionsPauseForAUserResponse() {
        let request = approval("item/tool/requestUserInput", params: ["questions": [["id": "q1", "question": "Which account?"]]])
        XCTAssertNil(request.automaticResponse(extendedAccess: true))
    }

    func testToolFormsWithDataOrUnknownConstraintsRemainBlocked() {
        let schemas: [[String: Any]] = [
            ["type": "object", "properties": ["password": ["type": "string"]]],
            ["type": "object", "properties": [:], "required": ["secret"]],
            ["type": "object", "properties": [:], "minProperties": 1],
            ["type": "object", "properties": [:], "required": "malformed"]
        ]
        for schema in schemas {
            let request = approval("mcpServer/elicitation/request", params: ["mode": "form", "message": "Confirm", "requestedSchema": schema])
            XCTAssertFalse(request.canAllow)
            XCTAssertEqual((request.response(allow: true)["result"] as? [String: Any])?["action"] as? String, "decline")
        }
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
