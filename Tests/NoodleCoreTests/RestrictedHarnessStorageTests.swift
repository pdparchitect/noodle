import XCTest
@testable import NoodleCore

final class RestrictedHarnessStorageTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        let first = try repo.createAgent(named: "First"), second = try repo.createAgent(named: "Second")
        return (root.appendingPathComponent("Home"), repo.directory(for: first.agent), repo.directory(for: second.agent))
    }

    func testCodexAndGrokCopyOnlyLoginAndPreservePrivateRefreshes() throws {
        for provider in [HarnessProvider.codex, .grokBuild] {
            let (home, first, second) = try fixture()
            let path = provider == .codex ? ".codex" : ".grok"
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let source = try WorkspaceMailbox(workspace: home, path: path, create: true)
            try source.writeData(Data("login-one".utf8), named: "auth.json")
            try source.writeData(Data("private history".utf8), named: "sessions.json")
            try source.writeData(Data("private hooks".utf8), named: "config.toml")
            for workspace in [first, second] {
                try RestrictedHarnessStorage.prepare(provider: provider, workspace: workspace, loginHome: home,
                    secret: { _, _ in XCTFail("No Keychain lookup needed"); return nil })
            }
            let a = try WorkspaceMailbox(workspace: first, path: ".noodle/home/" + path)
            let b = try WorkspaceMailbox(workspace: second, path: ".noodle/home/" + path)
            XCTAssertFalse(a.contains("sessions.json"))
            if provider == .codex { XCTAssertFalse(try String(decoding: a.read("config.toml", limit: 100), as: UTF8.self).contains("private hooks")) }
            try a.writeData(Data("refreshed".utf8), named: "auth.json")
            try RestrictedHarnessStorage.prepare(provider: provider, workspace: first, loginHome: home, secret: { _, _ in nil })
            XCTAssertEqual(try a.read("auth.json", limit: 100), Data("refreshed".utf8))
            XCTAssertEqual(try b.read("auth.json", limit: 100), Data("login-one".utf8))
            XCTAssertEqual(try source.read("auth.json", limit: 100), Data("login-one".utf8))
            try source.writeData(Data("new-sign-in".utf8), named: "auth.json")
            try RestrictedHarnessStorage.prepare(provider: provider, workspace: first, loginHome: home, secret: { _, _ in nil })
            XCTAssertEqual(try a.read("auth.json", limit: 100), Data("new-sign-in".utf8))
        }
    }

    func testMuseReadsOnlyItsProviderKeychainItemAndKeepsOtherProvidersOut() throws {
        let (home, workspace, _) = try fixture()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = try WorkspaceMailbox(workspace: home, path: ".config/muse", create: true)
        try source.writeData(Data(#"{"schema_version":1,"providers":{"meta":{"mechanism":"oauth","storage":"keychain"},"other":{"api_key":"unrelated"}}}"#.utf8), named: "auth.json")
        try RestrictedHarnessStorage.prepare(provider: .muse, workspace: workspace, loginHome: home, secret: { service, account in
            XCTAssertEqual(service, "ai.meta.dev.credentials"); XCTAssertEqual(account, "meta")
            return Data(#"{"secret_schema_version":1,"api_key":"fixture-key","access_token":"fixture-token"}"#.utf8)
        })
        let target = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.config/muse")
        let auth = try JSONSerialization.jsonObject(with: target.read("auth.json", limit: 4096)) as! [String: Any]
        let providers = auth["providers"] as! [String: [String: Any]]
        XCTAssertEqual(Array(providers.keys), ["meta"])
        XCTAssertEqual(providers["meta"]?["storage"] as? String, "file")
        XCTAssertEqual(providers["meta"]?["access_token"] as? String, "fixture-token")
    }

    func testFXImportsSelectedLoginWithoutSharedSkillsHooksOrMCP() throws {
        let (home, workspace, _) = try fixture()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = try WorkspaceMailbox(workspace: home, path: ".fx", create: true)
        try source.writeData(Data(#"{"provider":"gateway","credential_source":"fx_login","hooks":{"run":"private"},"workspaces":{"private":"config"}}"#.utf8), named: "settings.json")
        try source.writeData(Data("private MCP".utf8), named: "mcp.json")
        try RestrictedHarnessStorage.prepare(provider: .fx, workspace: workspace, loginHome: home, secret: { service, account in
            XCTAssertEqual(service, "FX_OAUTH_SESSION_V1"); XCTAssertEqual(account, NSUserName())
            return Data("fixture-login".utf8)
        })
        let target = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.fx")
        XCTAssertFalse(target.contains("mcp.json"))
        let settings = try String(decoding: target.read("settings.json", limit: 4096), as: UTF8.self)
        XCTAssertFalse(settings.contains("hooks")); XCTAssertFalse(settings.contains("workspaces"))
        let environment = try RestrictedAgentSandbox.environment(provider: .fx, home: home, workspace: workspace)
        XCTAssertEqual(environment["FX_DISABLE_KEYCHAIN"], "1")
        XCTAssertTrue(try XCTUnwrap(environment["HOME"]).hasPrefix(workspace.path + "/"))
    }

    func testRedirectedPrivateHomeCannotReceiveCredentials() throws {
        let (home, workspace, other) = try fixture()
        let noodle = try WorkspaceMailbox(workspace: workspace, path: ".noodle", create: true)
        try noodle.symlink("home", destination: other.path)
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent(".codex").path))
    }
}
