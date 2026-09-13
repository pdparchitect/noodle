import Foundation
import Darwin
import NoodleCore

@main enum MCPShimCLI {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.isEmpty || args == ["--help"] {
                print("./mcpshim tools|inspect|call [--tool NAME] [--input JSON]\nRun the mcpshim in the relevant skill directory; its connection is selected automatically.\nThe shared CLI also accepts --connection UUID for compatibility. Calls accept a JSON object through --input or stdin.\nNoodle must be running; manage connections and sign-in in Settings → Tools.")
                return
            }
            guard let action = MCPBridgeAction(rawValue: args[0]), args.count % 2 == 1 else {
                throw MCPConnectionError.message("Invalid command. Run mcpshim --help.")
            }
            var flags: [String: String] = [:]
            for index in stride(from: 1, to: args.count, by: 2) {
                let key = args[index]
                guard ["--connection", "--tool", "--input"].contains(key), flags[key] == nil else {
                    throw MCPConnectionError.message("Unknown or repeated option.")
                }
                flags[key] = args[index + 1]
            }
            guard action == .tools || !(flags["--tool"] ?? "").isEmpty,
                  action == .call || flags["--input"] == nil,
                  action != .tools || flags["--tool"] == nil else {
                throw MCPConnectionError.message("Specify a tool for inspect/call; input is only supported for call.")
            }
            let context = try MCPInvocationContext.resolve(invocationPath: CommandLine.arguments[0],
                currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            let id = flags["--connection"].flatMap(UUID.init(uuidString:))
            if flags["--connection"] != nil, id == nil {
                throw MCPConnectionError.message("Invalid connection identifier.")
            }
            guard id != nil || context.skillName != nil else {
                throw MCPConnectionError.message("Use the mcpshim inside the relevant skill directory so Noodle can select its connection.")
            }
            guard context.skillName == nil || id == nil else {
                throw MCPConnectionError.message("A skill-local mcpshim selects its own connection. Omit --connection.")
            }
            let folder = try MCPBridgeFiles.prepare(workspace: context.workspace)
            let session: MCPBridgeSession
            do {
                session = try JSONDecoder().decode(MCPBridgeSession.self,
                    from: MCPBridgeFiles.read(folder.appendingPathComponent("session.json"), limit: 4096))
            } catch { throw MCPConnectionError.message("Noodle's MCP bridge is not available. Open Noodle first.") }
            guard kill(session.processID, 0) == 0 || errno == EPERM else { throw MCPConnectionError.message("Noodle is not running. Open Noodle first.") }
            var arguments: Data?
            if action == .call {
                if let json = flags["--input"] { arguments = Data(json.utf8) }
                else if isatty(STDIN_FILENO) == 0 {
                    var input = Data()
                    while input.count <= MCPBridgeFiles.maxRequestBytes,
                          let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, MCPBridgeFiles.maxRequestBytes + 1 - input.count)),
                          !chunk.isEmpty {
                        input.append(chunk)
                    }
                    arguments = input
                }
                if arguments == nil || arguments?.isEmpty == true { arguments = Data("{}".utf8) }
                guard let arguments, arguments.count <= MCPBridgeFiles.maxRequestBytes,
                      (try? JSONSerialization.jsonObject(with: arguments)) is [String: Any] else {
                    throw MCPConnectionError.message("Tool arguments must be a JSON object no larger than 1 MB.")
                }
            }
            let request = MCPBridgeRequest(session: session.token, connectionID: id, skillName: context.skillName, action: action,
                                           tool: flags["--tool"], arguments: arguments)
            let stem = request.id.uuidString.lowercased()
            let requestFile = folder.appendingPathComponent(stem + ".request")
            let responseFile = folder.appendingPathComponent(stem + ".response")
            try MCPBridgeFiles.write(request, to: requestFile, workspace: context.workspace)
            defer {
                // These are this invocation's unique disposable IPC files only.
                try? FileManager.default.removeItem(at: requestFile)
                try? FileManager.default.removeItem(at: responseFile)
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 125
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let data = try? MCPBridgeFiles.read(responseFile, limit: MCPBridgeFiles.maxResponseBytes + 4096) {
                    let response = try JSONDecoder().decode(MCPBridgeResponse.self, from: data)
                    if let error = response.error { throw MCPConnectionError.message(error) }
                    guard let result = response.result else { throw MCPConnectionError.message("Empty MCP bridge response.") }
                    try FileHandle.standardOutput.write(contentsOf: result)
                    print("")
                    if let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
                       object["isError"] as? Bool == true { exit(1) }
                    return
                }
                guard kill(session.processID, 0) == 0 || errno == EPERM else {
                    throw MCPConnectionError.message("Noodle stopped during the request. Verify any remote action before retrying.")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw MCPConnectionError.message("MCP request timed out. Verify any remote action before retrying.")
        } catch {
            let data = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription], options: [.sortedKeys])
            try? FileHandle.standardError.write(contentsOf: data ?? Data("MCP request failed".utf8))
            try? FileHandle.standardError.write(contentsOf: Data("\n".utf8))
            exit(1)
        }
    }
}
