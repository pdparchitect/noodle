import Foundation

/// `messenger tool ...`: the agent-facing surface for every tool provider. It shares
/// the Messenger binary and identity resolution, but never the messaging bridge.
public enum ToolCLI {
    enum Command: Equatable {
        case providers, tools(String), inspect(String, String), call(String, String, [String])
    }

    static func parse(_ arguments: [String]) throws -> Command {
        let names = arguments.prefix(2)
        guard names.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else {
            throw ToolProviderError("Name the provider and tool before any options: messenger tool PROVIDER TOOL [--OPTION VALUE ...].")
        }
        switch arguments.count {
        case 0: return .providers
        case 1: return .tools(arguments[0])
        default:
            let flags = Array(arguments.dropFirst(2))
            if flags == ["--help"] { return .inspect(arguments[0], arguments[1]) }
            guard flags.first?.hasPrefix("--") != false else { throw ToolProviderError("Unexpected argument \(flags[0]). Options start with --.") }
            return .call(arguments[0], arguments[1], flags)
        }
    }

    /// `PROVIDER --run FILE|-` or `PROVIDER --eval CODE`, each with an optional `--timeout SECONDS`.
    /// The Messenger executable runs these itself, because a script streams output and needs a watchdog.
    public struct Script: Equatable {
        public enum Mode: Equatable { case run(String), eval(String) }
        public let provider: String
        public let mode: Mode
        public let timeout: Int
    }
    public static func script(_ arguments: [String]) throws -> Script? {
        guard arguments.count >= 2, !arguments[0].hasPrefix("-"), ["--run", "--eval"].contains(arguments[1]) else { return nil }
        guard arguments.count == 3 || (arguments.count == 5 && arguments[3] == "--timeout"), !arguments[2].isEmpty else {
            throw ToolProviderError("Use --run FILE, --run - for standard input, or --eval CODE, optionally with --timeout SECONDS.")
        }
        guard let timeout = arguments.count == 5 ? Int(arguments[4]) : 300, (1...3600).contains(timeout) else {
            throw ToolProviderError("--timeout must be an integer from 1 to 3600 seconds.")
        }
        return Script(provider: arguments[0], mode: arguments[1] == "--run" ? .run(arguments[2]) : .eval(arguments[2]), timeout: timeout)
    }

    /// One script operation, with the same file rules and result handling as the command line.
    public static func operation(_ action: MCPBridgeAction, provider: String, tool: String?, arguments: Data?, uri: String?, raw: Bool,
                                 workspace: URL, currentDirectory: URL) throws -> Data {
        func request(_ action: ToolBridgeAction, _ tool: String? = nil, _ input: Data? = nil) throws -> Data {
            try ToolBridgeClient.request(action, provider: provider, tool: tool, arguments: input, workspace: workspace, currentDirectory: currentDirectory)
        }
        switch action {
        case .tools: return try request(.tools)
        case .inspect: return try request(.inspect, tool)
        case .resources, .readResource, .call:
            let name = action == .call ? tool : action == .resources ? ConnectionToolProvider.resourcesTool : ConnectionToolProvider.readResourceTool
            var input = action == .readResource ? try JSONSerialization.data(withJSONObject: ["uri": uri ?? ""]) : arguments ?? Data("{}".utf8)
            if action == .call { input = try MCPFileContent.arguments(input, workspace: workspace, currentDirectory: currentDirectory) }
            return try MCPFileContent.result(try request(.call, name, input), workspace: workspace, callID: UUID(), raw: raw, resourceRead: action == .readResource)
        }
    }

    public static func run(_ arguments: [String], workspace: URL, currentDirectory: URL) -> MessengerCommandResult {
        do {
            // --agent-directory diagnostics may run from elsewhere; file paths then resolve from the workspace root.
            let root = workspace.resolvingSymlinksInPath().path, current = currentDirectory.resolvingSymlinksInPath().path
            let currentDirectory = current == root || current.hasPrefix(root + "/") ? currentDirectory : workspace
            func request(_ action: ToolBridgeAction, _ provider: String? = nil, _ tool: String? = nil, _ input: Data? = nil) throws -> Data {
                try ToolBridgeClient.request(action, provider: provider, tool: tool, arguments: input,
                                             workspace: workspace, currentDirectory: currentDirectory)
            }
            let output: Data
            switch try parse(arguments) {
            case .providers: output = try request(.providers)
            case .tools(let provider): output = try request(.tools, provider)
            case .inspect(let provider, let tool): output = try request(.inspect, provider, tool)
            case .call(let provider, let tool, let flags):
                // The schema types the flags, so numbers and booleans arrive as JSON values.
                let inspected = try JSONSerialization.jsonObject(with: request(.inspect, provider, tool)) as? [String: Any]
                let properties = (inspected?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
                let schema = try JSONSerialization.data(withJSONObject: inspected?["inputSchema"] as? [String: Any] ?? [:])
                // --raw belongs to this command unless the tool has an option of that name.
                let raw = properties["raw"] == nil && flags.contains("--raw")
                var options = raw ? flags.filter { $0 != "--raw" } : flags
                // `--input -` reads the JSON object from standard input, for large or awkward-to-quote values.
                if let index = options.firstIndex(of: "--input"), index + 1 < options.count, options[index + 1] == "-" {
                    var piped = Data()
                    while piped.count <= ToolBridgeClient.maxArgumentBytes,
                          let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty { piped.append(chunk) }
                    guard piped.count <= ToolBridgeClient.maxArgumentBytes else { throw ToolProviderError("Standard input exceeds 1 MiB.") }
                    options[index + 1] = String(decoding: piped, as: UTF8.self)
                }
                var input = try ToolArguments.build(options, schema: schema)
                // A connection's tools take file contents as base64 strings: "@path" reads a workspace
                // file, "@@" is a literal "@". Noodle's own tools receive files through their options.
                if (inspected?["_meta"] as? [String: Any])?["noodle/kind"] as? String == ToolProviderKind.connection.rawValue {
                    input = try MCPFileContent.arguments(input, workspace: workspace, currentDirectory: currentDirectory)
                }
                // Images, audio and other binary blocks become workspace files a bot can open.
                output = try MCPFileContent.result(try request(.call, provider, tool, input), workspace: workspace, callID: UUID(),
                                                   raw: raw, resourceRead: tool == ConnectionToolProvider.readResourceTool)
            }
            let failed = (try? JSONSerialization.jsonObject(with: output) as? [String: Any])?["isError"] as? Bool == true
            return MessengerCommandResult(exitCode: failed ? 1 : 0, standardOutput: String(decoding: output, as: UTF8.self) + "\n")
        } catch {
            return MessengerCommandResult(exitCode: 2, standardError: "messenger tool: \(error.localizedDescription)\n")
        }
    }
}
