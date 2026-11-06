import XCTest
@testable import NoodleCore

/// A Muse login keeps its sessions, their index and its processes' sockets in a folder of its own, so
/// its bots never reach another login's sessions or the person's own.
final class MuseProfileStorageTests: XCTestCase {
    func testEveryMuseLoginKeepsItsOwnSessionsAndSockets() throws {
        let profiles = HarnessProfileStore(root: URL(fileURLWithPath: "/tmp/noodle"))
        let work = HarnessProfile(id: UUID(), provider: .muse, displayName: "Work", createdAt: Date())
        let home = profiles.loginHome(work).path
        let environment = profiles.environment(work)
        for key in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"] {
            XCTAssertTrue(environment[key]?.hasPrefix(home + "/") == true, key)
        }
        let other = profiles.environment(HarnessProfile(id: UUID(), provider: .muse, displayName: "Other", createdAt: Date()))
        XCTAssertNotEqual(environment["XDG_DATA_HOME"], other["XDG_DATA_HOME"])
        XCTAssertNotEqual(environment["XDG_DATA_HOME"], profiles.environment(HarnessProfileStore.defaultRecord(.muse))["XDG_DATA_HOME"])
    }

    /// The installed Muse, offline with its echo provider, at a depth like Noodle's own storage.
    func testInstalledMuseResumesASessionInsideItsLoginsFolder() throws {
        let realHome = HarnessStorage.userHome
        let installed = realHome.appendingPathComponent(".local/bin/muse")
        guard FileManager.default.isExecutableFile(atPath: installed.path) else { throw XCTSkip("Muse is not installed") }
        let executable = try MuseExecutableTrust.executable(at: installed.path, home: realHome)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-muse-profile-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        // As deep as Noodle's container: its sockets must still fit.
        let storage = root.appendingPathComponent("Library/Containers/com.pdparchitect.noodle/Data/Library/Application Support/Noodle")
        let profiles = HarnessProfileStore(root: storage)
        let login = try profiles.create(provider: .muse, named: "Work")
        let personHome = root.appendingPathComponent("Home")
        let workspace = root.appendingPathComponent("Workspace")
        for folder in [personHome, workspace] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let environment = profiles.environment(login, over: ["HOME": personHome.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                                             "TMPDIR": FileManager.default.temporaryDirectory.path])
        func connect() throws -> ACPWireFixture {
            let wire = try ACPWireFixture(executable: executable, workspace: workspace,
                arguments: ["serve", "--disable-sandbox", "--trust-workspace"], environment: environment, requestTimeout: 15)
            do {
                let result = try wire.request("initialize", MuseProtocol.initialize)
                try MuseProtocol.validateInitialization(result, durable: true)
                let museHome = try XCTUnwrap(result["museHome"] as? String)
                XCTAssertTrue(URL(fileURLWithPath: museHome).resolvingSymlinksInPath().path
                    .hasPrefix(profiles.loginHome(login).resolvingSymlinksInPath().path + "/"), museHome)
                try wire.notify("initialized")
                return wire
            } catch { wire.stop(); throw error }
        }
        let first = try connect()
        let opened = try first.request("session/start", ["commandId": MuseProtocol.commandID(),
            "workspaceRoot": workspace.path, "providerId": "echo"])
        let session = try XCTUnwrap((opened["session"] as? [String: Any])?["sessionId"] as? String)
        first.stop()
        let second = try connect()
        defer { second.stop() }
        let resumed = try second.request("session/resume", ["commandId": MuseProtocol.commandID(), "sessionId": session, "excludeItems": true])
        XCTAssertEqual((resumed["session"] as? [String: Any])?["sessionId"] as? String, session)
        // Nothing reached the person's own Muse folders.
        XCTAssertFalse(FileManager.default.fileExists(atPath: personHome.appendingPathComponent(".local/share/muse").path))
    }
}
