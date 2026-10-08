import AppKit
import BrowserBridge
import BrowserExternal
import Foundation

/// noodle-browser: Noodle Browser for apps outside Noodle, as commands and as an MCP server.
/// It never touches the companion socket Noodle uses; it talks to the app's external socket,
/// and the app decides what each calling app may do.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("noodle-browser: \(message)\n".utf8))
    exit(1)
}

/// Starts Noodle Browser quietly if it is not running, then waits for its external socket.
func connect(_ url: URL) async throws {
    let build = BrowserBuildIdentity.current
    if FileManager.default.fileExists(atPath: url.path) { return }
    if NSRunningApplication.runningApplications(withBundleIdentifier: build.providerID).isEmpty {
        try await BrowserLaunch.openInBackground(at: Bundle.main.bundleURL)
    }
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw BrowserError("\(build.appName) is not accepting external tools. Turn on “Allow external tools” in its Settings, under External Tools.")
}

func client() throws -> BrowserExternalClient {
    let build = BrowserBuildIdentity.current
    guard BrowserBuildIdentity.processIdentity != nil else { throw BrowserError("Run noodle-browser from inside \(build.appName).") }
    let launcher = try ExternalAncestry.current()
    let team = try BrowserConnection.signingTeam()
    let socket = try BrowserExternal.socketURL()
    return BrowserExternalClient(environment: ProcessInfo.processInfo.environment,
        directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        stagingRoot: { try BrowserExternal.root() }) { request in
        try await connect(socket)
        let data = try JSONEncoder().encode(ExternalEnvelope(launcher: launcher, request: request))
        // The app may ask the person first, so the answer can take a while.
        let answer = try await Task.detached {
            try ExternalConnection.call(data, socket: socket, seconds: request.operation.timeout + 300) { fd in
                try ExternalConnection.requireSigned(fd, identifier: build.providerID, team: team)
            }
        }.value
        return try JSONDecoder().decode(BrowserResponse.self, from: answer)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
// `COMMAND --help` or `help COMMAND`: that command alone.
case let name? where arguments.dropFirst().contains("--help") || (name == "help" && arguments.count > 1):
    let command = name == "help" ? arguments[1] : name
    guard let usage = BrowserExternalClient.usage(for: command) else { fail("Unknown command \(command). Run noodle-browser help.") }
    print(usage, terminator: "")
case nil, "help", "--help", "-h":
    print(BrowserExternalClient.usage)
case "mcp":
    do {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        await MCPServer(name: "noodle-browser", version: version, instructions: BrowserExternalClient.instructions,
                        source: BrowserMCPSource(client: try client())).run()
    } catch { fail(error.localizedDescription) }
default:
    do {
        let (operation, options) = try BrowserExternalClient.parse(arguments)
        let result = try await client().run(operation, options: options)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    } catch { fail(error.localizedDescription) }
}
