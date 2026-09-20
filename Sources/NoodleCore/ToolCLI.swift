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

    /// `[PROVIDER] --run FILE|-` or `[PROVIDER] --eval CODE`, each with an optional `--timeout SECONDS`.
    /// A script reaches every provider through `tools`; naming one also binds `mcp` to it.
    /// The Messenger executable runs these itself, because a script streams output and needs a watchdog.
    public struct Script: Equatable {
        public enum Mode: Equatable { case run(String), eval(String) }
        public let provider: String?
        public let mode: Mode
        public let timeout: Int
    }
    public static func script(_ arguments: [String]) throws -> Script? {
        let provider = arguments.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        let rest = Array(arguments.dropFirst(provider == nil ? 0 : 1))
        guard let flag = rest.first, ["--run", "--eval"].contains(flag) else { return nil }
        guard rest.count == 2 || (rest.count == 4 && rest[2] == "--timeout"), !rest[1].isEmpty else {
            throw ToolProviderError("Use --run FILE, --run - for standard input, or --eval CODE, optionally with --timeout SECONDS.")
        }
        guard let timeout = rest.count == 4 ? Int(rest[3]) : 300, (1...3600).contains(timeout) else {
            throw ToolProviderError("--timeout must be an integer from 1 to 3600 seconds.")
        }
        return Script(provider: provider, mode: flag == "--run" ? .run(rest[1]) : .eval(rest[1]), timeout: timeout)
    }

    /// Each provider's kind, so a script knows which calls read "@path" arguments as files.
    public static func kinds(workspace: URL, currentDirectory: URL) throws -> [String: String] {
        let listed = try JSONSerialization.jsonObject(with: ToolBridgeClient.request(.providers, workspace: workspace, currentDirectory: currentDirectory))
        let providers = (listed as? [String: Any])?["providers"] as? [[String: Any]] ?? []
        return Dictionary(providers.compactMap { provider in (provider["id"] as? String).map { ($0, provider["kind"] as? String ?? "") } }) { $1 }
    }

    /// One script operation, with the same file rules and result handling as the command line.
    /// `expandsFiles` is true for tool connections, whose tools take file contents as base64.
    public static func operation(_ action: MCPBridgeAction, provider: String, tool: String?, arguments: Data?, uri: String?, raw: Bool,
                                 expandsFiles: Bool, workspace: URL, currentDirectory: URL) throws -> Data {
        func request(_ action: ToolBridgeAction, _ tool: String? = nil, _ input: Data? = nil) throws -> Data {
            try ToolBridgeClient.request(action, provider: provider, tool: tool, arguments: input, workspace: workspace, currentDirectory: currentDirectory)
        }
        switch action {
        case .tools: return try request(.tools)
        case .inspect: return try request(.inspect, tool)
        case .resources, .readResource, .call:
            let name = action == .call ? tool : action == .resources ? ConnectionToolProvider.resourcesTool : ConnectionToolProvider.readResourceTool
            var input = action == .readResource ? try JSONSerialization.data(withJSONObject: ["uri": uri ?? ""]) : arguments ?? Data("{}".utf8)
            if action == .call, expandsFiles { input = try MCPFileContent.arguments(input, workspace: workspace, currentDirectory: currentDirectory) }
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
