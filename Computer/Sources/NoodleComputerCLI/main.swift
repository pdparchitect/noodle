import AppKit
import ComputerBridge
import ComputerExternal
import Foundation

/// noodle-computer: Noodle Computer for apps outside Noodle, as commands and as an MCP server.
/// It never touches the companion socket Noodle uses; it talks to the app's external socket,
/// and the app decides what each calling app may do.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("noodle-computer: \(message)\n".utf8))
    exit(1)
}

/// Starts Noodle Computer quietly if it is not running, then waits for its external socket.
func connect(_ url: URL) async throws {
    let build = ComputerBuildIdentity.current
    if FileManager.default.fileExists(atPath: url.path) { return }
    if NSRunningApplication.runningApplications(withBundleIdentifier: build.providerID).isEmpty {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.open([ComputerLaunch.backgroundURL()], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
    }
    for _ in 0..<150 {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw ComputerBridgeError("\(build.appName) is not accepting external tools. Turn on “Allow external tools” in its Settings, under External Tools.")
}

func client() throws -> ComputerExternalClient {
    let build = ComputerBuildIdentity.current
    guard Bundle.main.bundleIdentifier == build.providerID else { throw ComputerBridgeError("Run noodle-computer from inside \(build.appName).") }
    let launcher = try ExternalAncestry.current()
    let team = try ComputerConnection.signingTeam()
    let socket = try ComputerExternal.socketURL()
    return ComputerExternalClient(environment: ProcessInfo.processInfo.environment,
        directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        stagingRoot: { try ComputerExternal.root() }) { request in
        try await connect(socket)
        let data = try JSONEncoder().encode(ExternalEnvelope(launcher: launcher, request: request))
        // The app may ask the person first, so the answer can take a while.
        let answer = try await Task.detached {
            try ExternalConnection.call(data, socket: socket, seconds: request.operation.timeout + 300) { fd in
                try ExternalConnection.requireSigned(fd, identifier: build.providerID, team: team)
            }
        }.value
        return try JSONDecoder().decode(ComputerResponse.self, from: answer)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
// `COMMAND --help` or `help COMMAND`: that command alone.
case let name? where arguments.dropFirst().contains("--help") || (name == "help" && arguments.count > 1):
    let command = name == "help" ? arguments[1] : name
    guard let usage = ComputerExternalClient.usage(for: command) else { fail("Unknown command \(command). Run noodle-computer help.") }
    print(usage, terminator: "")
case nil, "help", "--help", "-h":
    print(ComputerExternalClient.usage)
case "mcp":
    do {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        await MCPServer(name: "noodle-computer", version: version, instructions: ComputerExternalClient.instructions,
                        source: ComputerMCPSource(client: try client())).run()
    } catch { fail(error.localizedDescription) }
default:
    do {
        let (operation, options) = try ComputerExternalClient.parse(arguments)
        let result = try await client().run(operation, options: options)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    } catch { fail(error.localizedDescription) }
}
