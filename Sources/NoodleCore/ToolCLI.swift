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
                let schema = try JSONSerialization.data(withJSONObject: inspected?["inputSchema"] as? [String: Any] ?? [:])
                output = try request(.call, provider, tool, ToolArguments.build(flags, schema: schema))
            }
            let failed = (try? JSONSerialization.jsonObject(with: output) as? [String: Any])?["isError"] as? Bool == true
            return MessengerCommandResult(exitCode: failed ? 1 : 0, standardOutput: String(decoding: output, as: UTF8.self) + "\n")
        } catch {
            return MessengerCommandResult(exitCode: 2, standardError: "messenger tool: \(error.localizedDescription)\n")
        }
    }
}
