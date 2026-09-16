import Foundation
import Darwin
import NoodleCore
import NoodleMCPScripting

@main enum MCPShimCLI {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.isEmpty || args == ["--help"] {
                print("""
                ./mcpshim tools|inspect|call [--tool NAME] [--input JSON] [--raw]
                ./mcpshim resources
                ./mcpshim read-resource --uri URI [--raw]
                ./mcpshim run FILE|- [--timeout SECONDS]
                ./mcpshim eval JAVASCRIPT [--timeout SECONDS]
                Run the mcpshim in the relevant skill directory; its connection is selected automatically.
                The shared CLI also accepts --connection UUID for compatibility. Calls accept a JSON object through --input or stdin.
                JSON string values starting with @ read a workspace file as base64; @@ escapes a literal @.
                File paths are relative to the current directory. Encoded arguments must fit within 1 MiB.
                Binary results become files in .noodle/mcp-attachments, with paths in the JSON output.
                --raw preserves the original result JSON and saves no files. Results are limited to 8 MiB before extraction.
                Scripts use synchronous JavaScriptCore: mcp.tools(), mcp.inspect(name), mcp.call(name, input),
                mcp.resources(), mcp.readResource(uri). call/readResource accept a final {raw: true} option.
                print(value) writes a JSON line to stdout; console.log/info/warn/error/debug/dir write diagnostics to stderr.
                console.trace() writes a stack; console.assert(condition, ...values) logs failed assertions.
                Errors throw with source locations and available stacks; MCP tool errors include error.result.
                Only printed values become stdout. Console logging does not change the exit status.
                No imports, Node/browser APIs, or async workflows. Scripts run in a fresh context on one connection.
                Script files must be regular workspace files without links or '..'. Source limit: 1 MiB.
                Script limits: 100 MCP operations, 8 MiB combined output, 300 seconds (override --timeout: 1–3600).
                A timeout stops the script, but cannot undo a remote action. Verify changes before retrying.
                Noodle must be running; manage connections and sign-in in Settings → Tools.
                """)
                return
            }
            let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            if args[0] == "run" || args[0] == "eval" {
                try script(args, currentDirectory: currentDirectory)
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
                  !raw || action == .call || action == .readResource else {
                throw MCPConnectionError.message("Specify --tool for inspect/call or --uri for read-resource. --input is only for call; --raw is only for call/read-resource.")
            }
            let client = try client(connection: flags["--connection"], currentDirectory: currentDirectory)
            var arguments: Data?
            if action == .call {
                if let json = flags["--input"] { arguments = Data(json.utf8) }
                else if isatty(STDIN_FILENO) == 0 { arguments = try readStdin(limit: MCPBridgeFiles.maxRequestBytes) }
                if arguments?.isEmpty == true { arguments = nil }
            }
            let output = try client.perform(action, tool: flags["--tool"], arguments: arguments, uri: flags["--uri"], raw: raw)
            try FileHandle.standardOutput.write(contentsOf: output + Data("\n".utf8))
            if let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
               object["isError"] as? Bool == true { exit(1) }
        } catch {
            report(error.localizedDescription)
            exit(1)
        }
    }

    private static func script(_ args: [String], currentDirectory: URL) throws {
        guard args.count >= 2, !args[1].hasPrefix("--") else {
            throw MCPConnectionError.message("Specify run FILE, run - for stdin, or eval JAVASCRIPT.")
        }
        var flags: [String: String] = [:]
        var index = 2
        while index < args.count {
            let key = args[index]
            guard ["--connection", "--timeout"].contains(key), flags[key] == nil, index + 1 < args.count else {
                throw MCPConnectionError.message("Unknown or repeated script option.")
            }
            flags[key] = args[index + 1]
            index += 2
        }
        guard let seconds = Int(flags["--timeout"] ?? "300"), (1...3600).contains(seconds) else {
            throw MCPConnectionError.message("Script --timeout must be an integer from 1 to 3600 seconds.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
        let client = try client(connection: flags["--connection"], currentDirectory: currentDirectory, deadline: deadline)
        // A separate native queue can terminate even while JS loops forever or
        // blocks writing to a pipe. No private JavaScriptCore timeout API or JIT
        // entitlement is needed. Requests expire no later than this deadline.
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Noodle.mcpshim-deadline"))
        let timeoutMessage = Data("{\"error\":\"MCP script timed out after \(seconds) seconds. Verify any remote action before retrying.\"}\n".utf8)
        watchdog.setEventHandler {
            // Use an independent, nonblocking syscall: Foundation's file handle
            // may already be locked by a script blocked on a full output pipe.
            _ = fcntl(STDERR_FILENO, F_SETFL, fcntl(STDERR_FILENO, F_GETFL) | O_NONBLOCK)
            timeoutMessage.withUnsafeBytes { buffer in
                _ = Darwin.write(STDERR_FILENO, buffer.baseAddress, buffer.count)
            }
            _exit(1)
        }
        watchdog.schedule(deadline: .now() + Double(seconds))
        watchdog.resume()
        defer { watchdog.cancel() }

        do {
            try evaluateScript(args, client: client, currentDirectory: currentDirectory)
        } catch {
            // Keep the deadline active while reporting a script failure, too.
            // Actual newlines make the source location and stack readable in a terminal.
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func evaluateScript(_ args: [String], client: MCPBridgeClient, currentDirectory: URL) throws {
        let data: Data
        let sourceURL: URL
        if args[0] == "eval" {
            data = Data(args[1].utf8)
            sourceURL = URL(string: "mcpshim:///eval.js")!
        } else if args[1] == "-" {
            data = try readStdin(limit: MCPScript.maxSourceBytes)
            sourceURL = URL(string: "mcpshim:///stdin.js")!
        } else {
            let relative = try ComputerWorkspaceFiles.relativePath(args[1], currentDirectory: currentDirectory, workspace: client.context.workspace)
            let parts = relative.split(separator: "/").filter { $0 != "." }
            do {
                let folder = try WorkspaceMailbox(workspace: client.context.workspace, path: parts.dropLast().joined(separator: "/"))
                data = try folder.read(String(parts.last!), limit: MCPScript.maxSourceBytes)
            } catch {
                throw MCPConnectionError.message("Cannot read script. Use a regular UTF-8 workspace file without links, no larger than 1 MiB.")
            }
            sourceURL = client.context.workspace.appendingPathComponent(relative)
        }
        guard data.count <= MCPScript.maxSourceBytes, let source = String(data: data, encoding: .utf8) else {
            throw MCPConnectionError.message("JavaScript source must be UTF-8 and no larger than 1 MiB.")
        }
        try MCPScript.run(source, sourceURL: sourceURL, perform: { action, tool, arguments, uri, raw in
            try client.perform(action, tool: tool, arguments: arguments, uri: uri, raw: raw)
        }, output: { data, diagnostic in
            try (diagnostic ? FileHandle.standardError : FileHandle.standardOutput).write(contentsOf: data)
        })
    }

    private static func client(connection: String?, currentDirectory: URL, deadline: TimeInterval? = nil) throws -> MCPBridgeClient {
        let context = try MCPInvocationContext.resolve(invocationPath: CommandLine.arguments[0], currentDirectory: currentDirectory)
        let id = connection.flatMap(UUID.init(uuidString:))
        if connection != nil, id == nil { throw MCPConnectionError.message("Invalid connection identifier.") }
        return try MCPBridgeClient(context: context, currentDirectory: currentDirectory, connectionID: id, deadline: deadline)
    }

    private static func readStdin(limit: Int) throws -> Data {
        var input = Data()
        while input.count <= limit,
              let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, limit + 1 - input.count)), !chunk.isEmpty {
            input.append(chunk)
        }
        guard input.count <= limit else { throw MCPConnectionError.message("Standard input exceeds 1 MiB.") }
        return input
    }

    private static func report(_ message: String) {
        let data = try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys])
        try? FileHandle.standardError.write(contentsOf: (data ?? Data("MCP request failed".utf8)) + Data("\n".utf8))
    }
}
