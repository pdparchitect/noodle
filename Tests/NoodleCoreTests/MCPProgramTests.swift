import XCTest
import NoodleCore

final class MCPProgramTests: XCTestCase {

    func testHostAppliesItsOwnSeatbeltOutsideTheAppSandbox() {
        let command = MCPProgramHostLaunch.command(executable: "/usr/local/bin/npx", arguments: ["-y", "pkg"])
        XCTAssertEqual(command.executable, "/usr/bin/sandbox-exec")
        XCTAssertEqual(command.arguments, ["-p", MCPProgramHostLaunch.profile, "/usr/local/bin/npx", "-y", "pkg"])
        XCTAssertTrue(MCPProgramHostLaunch.profile.contains("(allow default)"))
        XCTAssertFalse(MCPProgramHostLaunch.profile.contains("(deny default)"))
        XCTAssertFalse(MCPProgramHostLaunch.profile.contains("app-sandbox"))
        XCTAssertFalse(MCPProgramHostLaunch.refusesAppSandbox(containerIdentifier: nil))
        XCTAssertFalse(MCPProgramHostLaunch.refusesAppSandbox(containerIdentifier: ""))
        XCTAssertTrue(MCPProgramHostLaunch.refusesAppSandbox(containerIdentifier: "com.pdparchitect.noodle"))
    }

    func testExecutableAndArgumentsStaySeparateFields() throws {
        let program = try MCPProgramRecord(name: "Anytype", executable: "npx", arguments: ["-y", "@anyproto/anytype-mcp"])
        XCTAssertEqual(program.arguments, ["-y", "@anyproto/anytype-mcp"])
        XCTAssertThrowsError(try MCPProgramRecord.validatedExecutable("npx -y @anyproto/anytype-mcp"))
        XCTAssertThrowsError(try MCPProgramRecord.validatedArgument("line\nbreak"))
    }

    func testConsentNamesTheCommandAndHidesSecrets() throws {
        let executable = URL(fileURLWithPath: "/usr/local/bin/npx")
        let directory = URL(fileURLWithPath: "/tmp/noodle-mcp/program", isDirectory: true)
        let text = MCPProgramRecord.consentText(executable: executable, arguments: ["-y", "@anyproto/anytype-mcp"],
                                                 workingDirectory: directory, user: "ada", mayDownload: true)
        XCTAssertTrue(text.contains("/usr/local/bin/npx"))
        XCTAssertTrue(text.contains("-y @anyproto/anytype-mcp"))
        XCTAssertTrue(text.contains(directory.path))
        XCTAssertTrue(text.contains("ada"))
        XCTAssertTrue(text.contains("outside any agent's sandbox"))
        XCTAssertTrue(text.contains("download and run code"))
        XCTAssertFalse(text.contains("super-secret"))
        XCTAssertTrue(MCPProgramRecord.mayDownloadCode(executable: "npx", arguments: ["-y"]))
        XCTAssertFalse(MCPProgramRecord.mayDownloadCode(executable: "/bin/cat", arguments: []))
    }

    func testSubjectChangesWhenTheCommandChanges() {
        let directory = URL(fileURLWithPath: "/tmp/noodle/programs/1", isDirectory: true)
        let first = MCPProgramRecord.subject(executable: URL(fileURLWithPath: "/usr/bin/npx"), arguments: ["-y"],
                                              workingDirectory: directory, environmentNames: ["OPENAPI_MCP_HEADERS"])
        let second = MCPProgramRecord.subject(executable: URL(fileURLWithPath: "/usr/bin/npx"), arguments: ["-y", "other"],
                                               workingDirectory: directory, environmentNames: ["OPENAPI_MCP_HEADERS"])
        XCTAssertNotEqual(first, second)
    }

    func testResolveDoesNotTreatANameAsAShellCommand() throws {
        let found = try MCPProgramRecord.resolveExecutable("npx", lookup: { name in
            XCTAssertEqual(name, "npx")
            return URL(fileURLWithPath: "/usr/local/bin/npx")
        })
        XCTAssertEqual(found.path, "/usr/local/bin/npx")
        XCTAssertThrowsError(try MCPProgramRecord.resolveExecutable("npx", lookup: { _ in nil }))
        let absolute = try MCPProgramRecord.resolveExecutable("/bin/cat", lookup: { _ in
            XCTFail("An absolute path is not searched")
            return nil
        })
        XCTAssertEqual(absolute.path, "/bin/cat")
    }

    func testEnvironmentIsOnlyTheDeclaredNamesPlusTheMinimalSet() {
        let environment = MCPProgramRecord.environment(
            values: ["OPENAPI_MCP_HEADERS": "secret-value", "OTHER": "no"],
            names: ["OPENAPI_MCP_HEADERS"],
            minimal: MCPProgramRecord.minimalEnvironment(user: "ada", temporaryDirectory: "/tmp"))
        XCTAssertEqual(environment["OPENAPI_MCP_HEADERS"], "secret-value")
        XCTAssertNil(environment["OTHER"])
        XCTAssertEqual(environment["USER"], "ada")
        XCTAssertEqual(environment["LANG"], "C")
        XCTAssertFalse(environment.keys.contains("HOME"))
    }

    func testStderrRedactsSecretsAndStdoutMustBeMCP() throws {
        let redacted = MCPProgramRecord.redact("header secret-value failed", secrets: ["secret-value", "ab"])
        XCTAssertEqual(redacted, "header [redacted] failed")
        XCTAssertThrowsError(try MCPProgramRecord.mcpMessageLine("hello from the program")) { error in
            XCTAssertTrue(error.localizedDescription.contains("other than an MCP message"))
        }
        let data = try MCPProgramRecord.mcpMessageLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("hello"))
    }

    func testCrashesBackOffThenFailAndIdleStopsARunningProgram() {
        var life = MCPProgramRecord.Lifecycle()
        life.started(at: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(life.isIdle(at: Date(timeIntervalSince1970: 10)))
        XCTAssertTrue(life.isIdle(at: Date(timeIntervalSince1970: MCPProgramRecord.idleSeconds)))
        var delays: [TimeInterval] = []
        for _ in 0..<MCPProgramRecord.maximumRestarts {
            delays.append(life.crashed()!)
        }
        XCTAssertNil(life.crashed())
        XCTAssertTrue(life.failed)
        XCTAssertEqual(delays, [0.25, 0.5, 1])
        XCTAssertTrue(MCPProgramRecord.parentHasExited(1))
        XCTAssertFalse(MCPProgramRecord.parentHasExited(100))
        XCTAssertTrue(MCPProgramRecord.assignmentWarning(restricted: true)?.contains("outside this agent's sandbox") == true)
        XCTAssertNil(MCPProgramRecord.assignmentWarning(restricted: false))
    }

    func testOlderBuildDropsAProgramAndStillValidatesPublicConnections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var registry = MCPRegistry()
        let remote = try MCPConnectionRecord(name: "Notion", endpoint: URL(string: "https://mcp.notion.com/mcp")!)
        let program = try MCPProgramRecord(name: "Local", executable: "npx", arguments: ["-y", "@anyproto/anytype-mcp"],
                                           environmentNames: ["OPENAPI_MCP_HEADERS"])
        registry.connections = [remote]
        registry.programs = [program]
        let agent = UUID()
        try registry.assign([remote.id, program.id], to: agent)
        try registry.save(root: root)
        let saved = try String(contentsOf: root.appendingPathComponent("MCP/connections.json"), encoding: .utf8)
        XCTAssertTrue(saved.contains("programs"))
        XCTAssertFalse(saved.contains("secret-value"))
        struct OldRegistry: Decodable {
            var connections: [MCPConnectionRecord]
            var assignments: [String: [UUID]]
        }
        let old = try JSONDecoder().decode(OldRegistry.self, from: Data(saved.utf8))
        XCTAssertEqual(old.connections.map(\.id), [remote.id])
        XCTAssertNoThrow(try MCPConnectionRecord.validatedEndpoint(old.connections[0].endpoint))
        let loaded = try MCPRegistry.load(root: root)
        XCTAssertEqual(loaded.programs.map(\.id), [program.id])
        XCTAssertEqual(loaded.assignedPrograms(to: agent).map(\.id), [program.id])
    }
}
