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

    func testRuntimePermissionsFollowSavedAccessForTheCurrentTurnOnly() throws {
        for method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"] {
            let permissions: [String: Any] = ["fileSystem": ["read": ["/tmp/one-file"]], "network": ["enabled": true]]
            let request = request(method, params: ["permissions": permissions])
            for extended in [false, true] {
                for current in [false, true] {
                    let result = try XCTUnwrap(request.response(extendedAccess: extended, isCurrent: current)["result"] as? [String: Any])
                    if method == "item/permissions/requestApproval" {
                        XCTAssertEqual(result["scope"] as? String, "turn")
                        let actual = try XCTUnwrap(result["permissions"] as? [String: Any])
                        XCTAssertEqual(try JSONSerialization.data(withJSONObject: actual, options: .sortedKeys),
                            try JSONSerialization.data(withJSONObject: extended && current ? permissions : [:], options: .sortedKeys))
                    } else {
                        XCTAssertEqual(result["decision"] as? String, extended && current ? "accept" : "decline")
                    }
                }
            }
        }
    }

    func testUnsupportedOfferedDecisionCannotBeInvented() {
        let request = request("item/commandExecution/requestApproval", params: ["availableDecisions": ["decline", "cancel"]])
        XCTAssertEqual((request.response(extendedAccess: true)["result"] as? [String: String])?["decision"], "decline")
    }

    func testQuestionsAreSkippedWithoutInventingAnAnswer() throws {
        let request = request("item/tool/requestUserInput", params: ["questions": [["id": "q1", "question": "Which account?"]]])
        for extended in [false, true] {
            let result = try XCTUnwrap(request.response(extendedAccess: extended)["result"] as? [String: Any])
            XCTAssertTrue(try XCTUnwrap(result["answers"] as? [String: Any]).isEmpty)
        }
    }

    func testRoutineToolConfirmationIsAcceptedOnlyForTheCurrentRequest() throws {
        let request = request("mcpServer/elicitation/request", params: [
            "mode": "form", "message": "Allow Browser use?",
            "requestedSchema": ["type": "object", "properties": [String: Any]()]
        ])
        for extended in [false, true] {
            let result = try XCTUnwrap(request.response(extendedAccess: extended)["result"] as? [String: Any])
            XCTAssertEqual(result["action"] as? String, "accept")
            XCTAssertTrue(try XCTUnwrap(result["content"] as? [String: Any]).isEmpty)
            let stale = request.response(extendedAccess: extended, isCurrent: false)["result"] as? [String: Any]
            XCTAssertEqual(stale?["action"] as? String, "decline")
            XCTAssertTrue(stale?["content"] is NSNull)
        }
    }

    func testToolFormsWithDataOrUnknownConstraintsRemainBlocked() {
        let schemas: [[String: Any]] = [
            ["type": "object", "properties": ["password": ["type": "string"]]],
            ["type": "object", "properties": [:], "required": ["secret"]],
            ["type": "object", "properties": [:], "minProperties": 1],
            ["type": "object", "properties": [:], "required": "malformed"]
        ]
        for schema in schemas {
            let request = request("mcpServer/elicitation/request", params: ["mode": "form", "message": "Confirm", "requestedSchema": schema])
            XCTAssertEqual((request.response(extendedAccess: true)["result"] as? [String: Any])?["action"] as? String, "decline")
        }
    }

    func testURLToolElicitationDoesNotManufactureConsent() {
        let request = request("mcpServer/elicitation/request", params: ["mode": "url", "url": "https://example.invalid/sign-in"])
        XCTAssertEqual((request.response(extendedAccess: true)["result"] as? [String: Any])?["action"] as? String, "decline")
    }

    func testUnknownRequestFailsClosed() {
        let request = request("future/permission/request", params: [:])
        XCTAssertNotNil(request.response(extendedAccess: true)["error"])
    }

    func testPlainResponseIsNotAServerRequest() {
        XCTAssertNil(CodexRuntimeRequest(message: ["id": 1, "result": [:]]))
    }

    private func request(_ method: String, params: [String: Any]) -> CodexRuntimeRequest {
        CodexRuntimeRequest(message: ["id": "request-1", "method": method, "params": params])!
    }
}
