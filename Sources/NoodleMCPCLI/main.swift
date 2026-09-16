import Foundation
import Darwin
import NoodleCore

@main enum MCPShimCLI {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.isEmpty || args == ["--help"] {
                print("""
                ./mcpshim tools|inspect|call [--tool NAME] [--input JSON] [--raw]
                ./mcpshim resources
                ./mcpshim read-resource --uri URI [--raw]
                Run the mcpshim in the relevant skill directory; its connection is selected automatically.
                The shared CLI also accepts --connection UUID for compatibility. Calls accept a JSON object through --input or stdin.
                JSON string values starting with @ read a workspace file as base64; @@ escapes a literal @.
                File paths are relative to the current directory. Encoded arguments must fit within 1 MiB.
                Binary results become files in .noodle/mcp-attachments, with paths in the JSON output.
                --raw preserves the original result JSON and saves no files. Results are limited to 8 MiB before extraction.
                Noodle must be running; manage connections and sign-in in Settings → Tools.
                """)
                return
            }
            guard let action = MCPBridgeAction(rawValue: args[0]) else {
                throw MCPConnectionError.message("Invalid command. Run mcpshim --help.")
            }
            var flags: [String: String] = [:]
            var raw = false
            var index = 1
            while index < args.count {
                let key = args[index]
                if key == "--raw", !raw { raw = true; index += 1; continue }
                guard ["--connection", "--tool", "--input", "--uri"].contains(key), flags[key] == nil,
                      index + 1 < args.count else {
                    throw MCPConnectionError.message("Unknown or repeated option.")
                }
                flags[key] = args[index + 1]
                index += 2
            }
            let needsTool = action == .inspect || action == .call
            guard needsTool ? !(flags["--tool"] ?? "").isEmpty : flags["--tool"] == nil,
                  action == .call || flags["--input"] == nil,
                  action == .readResource ? !(flags["--uri"] ?? "").isEmpty : flags["--uri"] == nil,
                  (flags["--uri"]?.utf8.count ?? 0) <= 4096,
                  !raw || action == .call || action == .readResource else {
                throw MCPConnectionError.message("Specify --tool for inspect/call or --uri for read-resource. --input is only for call; --raw is only for call/read-resource.")
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
                arguments = try MCPFileContent.arguments(arguments!, workspace: context.workspace,
                    currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            }
            let request = MCPBridgeRequest(session: session.token, connectionID: id, skillName: context.skillName, action: action,
                                           tool: flags["--tool"], arguments: arguments, uri: flags["--uri"])
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
                    let output: Data
                    if action == .call || action == .readResource {
                        do {
                            output = try MCPFileContent.result(result, workspace: context.workspace, callID: request.id,
                                raw: raw, resourceRead: action == .readResource)
                        } catch {
                            throw MCPConnectionError.message("Could not prepare MCP result files: \(error.localizedDescription) The remote request has already completed; verify any remote changes before retrying.")
                        }
                    } else { output = result }
                    try FileHandle.standardOutput.write(contentsOf: output)
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
