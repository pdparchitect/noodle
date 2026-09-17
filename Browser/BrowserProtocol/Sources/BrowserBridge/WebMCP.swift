import Foundation

public extension BrowserOperation {
    var commandName: String {
        switch self {
        case .webMCPList: "webmcp list"
        case .webMCPCall: "webmcp call"
        default: rawValue
        }
    }

    /// Keep the wire operations stable while presenting a namespaced CLI.
    static func expandingWebMCPCommand(_ arguments: [String]) throws -> [String] {
        guard arguments.first == "webmcp" else { return arguments }
        guard arguments.count >= 2 else { throw BrowserError("Use browser webmcp list or browser webmcp call. See --help.") }
        let operation: Self
        switch arguments[1] {
        case "list": operation = .webMCPList
        case "call": operation = .webMCPCall
        case "--help": return ["--help"]
        default: throw BrowserError("Unknown WebMCP command. Use list or call.")
        }
        return [operation.rawValue] + arguments.dropFirst(2)
    }
}

public extension BrowserRequest {
    func validateWebMCP() throws {
        guard operation == .webMCPCall else {
            guard toolID == nil, arguments == nil else { throw BrowserError("Tool and arguments require webmcp call.") }
            return
        }
        guard let toolID, !toolID.isEmpty, toolID.utf8.count <= 256,
              !toolID.utf8.contains(0) else { throw BrowserError("Specify --tool ID returned by webmcp list.") }
        guard let arguments, arguments.utf8.count <= 1_048_576,
              let data = arguments.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw BrowserError("WebMCP arguments must be a JSON object of at most 1 MiB. Use --args or --args-file.")
        }
    }
}
