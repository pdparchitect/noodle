import XCTest
@testable import NoodleCore

final class AgentAccessTests: XCTestCase {
    func testEditingOrCopyingHarnessConfigurationCannotCreateAGrant() {
        var bot = AgentRecord(displayName: "Original", harnessIdentifier: "claude-code")
        var configuration = AgentAccessConfiguration()
        configuration.authorizeSelectedHarness(for: bot)
        XCTAssertTrue(configuration.isExtended(for: bot))
        bot.harnessIdentifier = "muse"
        XCTAssertFalse(configuration.isExtended(for: bot))
        let copy = AgentRecord(displayName: "Copy", harnessIdentifier: "claude-code")
        XCTAssertFalse(configuration.isExtended(for: copy))
        configuration.remove(bot.id)
        bot.harnessIdentifier = "claude-code"
        XCTAssertFalse(configuration.isExtended(for: bot))
    }

    func testLegacyHarnessGrantSnapshotRunsOnce() {
        let suite = "Noodle.AccessTests.\(UUID())", bot = AgentRecord(displayName: "Legacy", harnessIdentifier: "claude-code")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = AgentAccessConfiguration()
        configuration.migrateRequiredHarnessGrants([bot], in: defaults)
        XCTAssertTrue(configuration.isExtended(for: bot))
        let imported = AgentRecord(displayName: "Imported", harnessIdentifier: "claude-code")
        configuration = .load(from: defaults)
        configuration.migrateRequiredHarnessGrants([bot, imported], in: defaults)
        XCTAssertFalse(configuration.isExtended(for: imported))
    }
    func testHarnessAccessCapabilities() {
        for provider in [HarnessProvider.codex, .apple, .fx, .grokBuild, .muse] {
            XCTAssertTrue(provider.supportsRestrictedAccess)
        }
        for provider in [HarnessProvider.claudeCode] {
            XCTAssertFalse(provider.supportsRestrictedAccess)
        }
    }

    func testFormerlyRequiredGrantsDoNotOverrideTheSavedRestrictedPreference() {
        let suite = "Noodle.AccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for provider in [HarnessProvider.fx, .grokBuild, .muse] {
            let bot = AgentRecord(displayName: "Existing", harnessIdentifier: provider.rawValue)
            defaults.set([bot.id.uuidString: [provider.rawValue]], forKey: "Noodle.access.requiredHarnessGrants")
            var access = AgentAccessConfiguration.load(from: defaults)
            XCTAssertFalse(access.isExtended(for: bot))
            access.setExtended(true, for: bot.id)
            XCTAssertTrue(access.isExtended(for: bot))
            access.setExtended(false, for: bot.id)
            access.save(to: defaults)
            XCTAssertFalse(AgentAccessConfiguration.load(from: defaults).isExtended(for: bot))
        }
    }

    func testRequiredHarnessNeedsAnExplicitGrantAfterRelaunch() {
        let suite = "Noodle.AccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for provider in HarnessProvider.allCases where !provider.supportsRestrictedAccess {
            let bot = AgentRecord(displayName: "Existing bot", harnessIdentifier: provider.rawValue)
            var configuration = AgentAccessConfiguration()
            XCTAssertFalse(configuration.isExtended(for: bot))
            configuration.authorizeSelectedHarness(for: bot)
            configuration.setExtended(false, for: bot.id)
            configuration.save(to: defaults)
            let restored = AgentAccessConfiguration.load(from: defaults)
            XCTAssertTrue(restored.isExtended(for: bot))
            XCTAssertFalse(restored.isExtended(bot.id), "Required access must not overwrite the saved preference")
        }
    }

    func testSwitchingHarnessRestoresDiscretionaryAccessPreference() {
        var bot = AgentRecord(displayName: "Bot", harnessIdentifier: HarnessProvider.codex.rawValue)
        var configuration = AgentAccessConfiguration()
        XCTAssertFalse(configuration.isExtended(for: bot))
        bot.harnessIdentifier = HarnessProvider.claudeCode.rawValue
        XCTAssertFalse(configuration.isExtended(for: bot))
        configuration.authorizeSelectedHarness(for: bot)
        XCTAssertTrue(configuration.isExtended(for: bot))
        bot.harnessIdentifier = HarnessProvider.codex.rawValue
        XCTAssertFalse(configuration.isExtended(for: bot))
        configuration.setExtended(true, for: bot.id)
        XCTAssertTrue(configuration.isExtended(for: bot))
        configuration.setExtended(false, for: bot.id)
        XCTAssertFalse(configuration.isExtended(for: bot))
    }

    func testUnknownOrMissingHarnessDoesNotImplyAutonomousAccess() {
        for identifier in [nil, "unknown"] as [String?] {
            let bot = AgentRecord(displayName: "Bot", harnessIdentifier: identifier)
            XCTAssertFalse(AgentAccessConfiguration().isExtended(for: bot))
        }
    }

    func testNewBotsDefaultToRestrictedAccess() {
        XCTAssertFalse(AgentAccessConfiguration().isExtended(UUID()))
    }

    func testRestrictionPersistsPerBotAndCanBeRemoved() {
        let suite = "Noodle.AccessTests.\(UUID())"
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

    func testMigrationPreservesExistingAccessButDoesNotGrantNewBots() {
        let suite = "Noodle.AccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previouslyExtendedBot = UUID()
        let previouslyRestrictedBot = UUID()
        defaults.set([previouslyRestrictedBot.uuidString], forKey: "Noodle.access.restrictedAgents")

        let existing: Set<UUID> = [previouslyExtendedBot, previouslyRestrictedBot]
        let configuration = AgentAccessConfiguration.migrateExistingAgents(existing, in: defaults)
        XCTAssertTrue(configuration.isExtended(previouslyExtendedBot))
        XCTAssertFalse(configuration.isExtended(previouslyRestrictedBot))
        let newBot = UUID()
        XCTAssertFalse(configuration.isExtended(newBot))
        let reloaded = AgentAccessConfiguration.migrateExistingAgents(existing.union([newBot]), in: defaults)
        XCTAssertEqual(reloaded, configuration)
        XCTAssertFalse(reloaded.isExtended(newBot))
    }

    func testMigrationPreservesPreviousImplicitAutonomousAccess() {
        let suite = "Noodle.AccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bot = UUID()
        let configuration = AgentAccessConfiguration.migrateExistingAgents([bot], in: defaults)
        XCTAssertTrue(configuration.isExtended(bot))
        XCTAssertFalse(configuration.isExtended(UUID()))
    }

    func testFreshInstallAndRelaunchDoNotGrantNewBots() {
        let suite = "Noodle.AccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = AgentAccessConfiguration.migrateExistingAgents([], in: defaults)
        let bot = UUID()
        let configuration = AgentAccessConfiguration.migrateExistingAgents([bot], in: defaults)
        XCTAssertFalse(configuration.isExtended(bot))
    }

    func testRemovingGrantCannotBeUndoneByMigration() {
        let suite = "Noodle.AccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bot = UUID()
        var configuration = AgentAccessConfiguration.migrateExistingAgents([bot], in: defaults)
        configuration.remove(bot)
        configuration.save(to: defaults)
        XCTAssertFalse(AgentAccessConfiguration.migrateExistingAgents([bot], in: defaults).isExtended(bot))
    }

    func testMalformedNewStorageFailsClosedInsteadOfMigratingLegacyDefaults() {
        let suite = "Noodle.AccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bot = UUID()
        defaults.set("invalid", forKey: "Noodle.access.autonomousAgents")
        XCTAssertFalse(AgentAccessConfiguration.migrateExistingAgents([bot], in: defaults).isExtended(bot))
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
