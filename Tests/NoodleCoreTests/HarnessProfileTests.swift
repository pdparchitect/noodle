import XCTest
@testable import NoodleCore

final class HarnessProfileTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private var store: HarnessProfileStore { repository.harnessProfiles }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-profiles-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent("Noodle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    func testProfilesKeepTheirLoginInsideTheirOwnFolder() throws {
        XCTAssertEqual(try store.load(), [])
        let work = try store.create(provider: .codex, named: "  Work  ", now: Date(timeIntervalSince1970: 1))
        let personal = try store.create(provider: .codex, named: "Personal", now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(try store.load().map(\.displayName), ["Work", "Personal"])
        XCTAssertEqual(store.accountHome(work).path,
            root.appendingPathComponent("HarnessProfiles/\(work.id.uuidString.lowercased())/home/.codex").path)
        XCTAssertEqual(try String(contentsOf: store.accountHome(work).appendingPathComponent("config.toml"), encoding: .utf8),
            "cli_auth_credentials_store = \"file\"\n")

        XCTAssertEqual(try store.rename(work, to: "Client").displayName, "Client")
        try store.delete(personal)
        XCTAssertEqual(try store.load().map(\.displayName), ["Client"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.loginHome(personal).path))

        XCTAssertThrowsError(try store.create(provider: .grokBuild, named: "Other"))
        XCTAssertThrowsError(try store.create(provider: .codex, named: " \n "))
    }

    func testBotSelectionIsPrivateAndSurvivesRecordUpdates() throws {
        var agent = try repository.createAgent(named: "Profile Bot", harnessIdentifier: "codex").agent
        let workspace = repository.storage(for: agent.id).workspace
        XCTAssertNil(try store.selected(workspace: workspace, provider: .codex))
        XCTAssertFalse(try String(contentsOf: repository.storage(for: agent.id).configuration, encoding: .utf8).contains("harnessProfile"))

        let profile = try store.create(provider: .codex, named: "Work")
        try repository.updateAgentHarnessProfile(agent, profile: profile.id)
        agent = try repository.renameAgent(agent, to: "Renamed Bot")
        XCTAssertEqual(try repository.loadAgentHarnessProfile(agent), profile.id)
        XCTAssertEqual(try store.selected(workspace: workspace, provider: .codex), profile)
        XCTAssertFalse(try XCTUnwrap(String(data: JSONEncoder().encode(agent), encoding: .utf8)).contains(profile.id.uuidString))

        try repository.updateAgentHarnessProfile(agent, profile: nil)
        XCTAssertNil(try store.selected(workspace: workspace, provider: .codex))
    }

    func testUnavailableProfileFailsClosed() throws {
        let agent = try repository.createAgent(named: "Profile Bot", harnessIdentifier: "codex").agent
        let workspace = repository.storage(for: agent.id).workspace
        let profile = try store.create(provider: .codex, named: "Work")
        try repository.updateAgentHarnessProfile(agent, profile: profile.id)

        // The bot's harness no longer matches the profile's.
        XCTAssertThrowsError(try store.selected(workspace: workspace, provider: .claudeCode))

        // A redirected login home must not stand in for the profile.
        let home = store.loginHome(profile), moved = home.deletingLastPathComponent().appendingPathComponent("moved")
        try FileManager.default.moveItem(at: home, to: moved)
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: moved)
        XCTAssertThrowsError(try store.selected(workspace: workspace, provider: .codex))
        try FileManager.default.removeItem(at: home)
        try FileManager.default.moveItem(at: moved, to: home)
        XCTAssertEqual(try store.selected(workspace: workspace, provider: .codex), profile)

        try store.delete(profile)
        XCTAssertThrowsError(try store.selected(workspace: workspace, provider: .codex)) {
            XCTAssertTrue($0.localizedDescription.contains("profile is unavailable"))
        }
    }

    func testRestrictedBotIsSeededFromItsProfileLogin() throws {
        let agent = try repository.createAgent(named: "Profile Bot", harnessIdentifier: "codex").agent
        let workspace = repository.storage(for: agent.id).workspace
        let profile = try store.create(provider: .codex, named: "Work")
        let seeded = RestrictedHarnessStorage.home(workspace: workspace).appendingPathComponent(".codex/auth.json")

        // Not signed in yet: never fall back to another account.
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: store.loginHome(profile)))

        try Data("work-login".utf8).write(to: store.accountHome(profile).appendingPathComponent("auth.json"))
        try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: store.loginHome(profile))
        XCTAssertEqual(try Data(contentsOf: seeded), Data("work-login".utf8))

        // Switching profile replaces the bot's login with the other account.
        let other = try store.create(provider: .codex, named: "Personal")
        try Data("personal-login".utf8).write(to: store.accountHome(other).appendingPathComponent("auth.json"))
        try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: store.loginHome(other))
        XCTAssertEqual(try Data(contentsOf: seeded), Data("personal-login".utf8))
    }
}
