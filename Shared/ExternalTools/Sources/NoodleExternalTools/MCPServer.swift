import Foundation

/// The tools an MCP server offers, as MCP JSON: a `tools/list` array and `tools/call` results.
public protocol MCPToolSource: Sendable {
    func tools() async throws -> Data
    func call(_ name: String, arguments: Data) async -> Data
}

/// A Model Context Protocol server over standard input and output, one JSON-RPC message per line.
public struct MCPServer: Sendable {
    /// Oldest first; a client asking for another gets the newest.
    static let versions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    let name: String
    let version: String
    let instructions: String
    let source: MCPToolSource

    public init(name: String, version: String, instructions: String, source: MCPToolSource) {
        self.name = name; self.version = version; self.instructions = instructions; self.source = source
    }

    /// Serves until standard input closes. Calls run side by side; answers are written whole.
    public func run(input: FileHandle = .standardInput, output sink: FileHandle = .standardOutput) async {
        let output = Output(handle: sink)
        await withTaskGroup(of: Void.self) { group in
            // Only a newline ends a message: Foundation's lines also break at U+2028, U+2029 and
            // U+0085, which JSON may carry unescaped inside a string.
            var line = Data()
            do {
                for try await byte in input.bytes {
                    guard byte == UInt8(ascii: "\n") else { line.append(byte); continue }
                    let message = line
                    line = Data()
                    guard !message.isEmpty else { continue }
                    group.addTask { if let answer = await handle(message) { await output.write(answer) } }
                }
            } catch {}
            if !line.isEmpty {
                let message = line
                group.addTask { if let answer = await handle(message) { await output.write(answer) } }
            }
        }
    }

    /// The answer to one message, or nil for a notification.
    public func handle(_ data: Data) async -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return Self.answer(id: NSNull(), error: (-32700, "Parse error"))
        }
        guard let message = parsed as? [String: Any] else { return Self.answer(id: NSNull(), error: (-32600, "Invalid Request")) }
        // A client's own answers carry no method; notifications carry no id. Neither is answered.
        guard let method = message["method"] as? String, let id = message["id"] else { return nil }
        // An id is a string or a number; JSON's true and false arrive as numbers too.
        let usable = id is String || (id as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true
        guard usable else { return Self.answer(id: NSNull(), error: (-32600, "Invalid Request")) }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return Self.answer(id: id, result: [
                "protocolVersion": Self.versions.contains(asked) ? asked : Self.versions.last!,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": name, "version": version],
                "instructions": instructions])
        case "ping":
            return Self.answer(id: id, result: [:])
        case "tools/list":
            do {
                let tools = try JSONSerialization.jsonObject(with: try await source.tools())
                return Self.answer(id: id, result: ["tools": tools])
            } catch { return Self.answer(id: id, error: (-32603, error.localizedDescription)) }
        case "tools/call":
            guard let tool = params["name"] as? String else { return Self.answer(id: id, error: (-32602, "Missing tool name")) }
            let arguments = (try? JSONSerialization.data(withJSONObject: params["arguments"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)
            let result = (try? JSONSerialization.jsonObject(with: await source.call(tool, arguments: arguments))) ?? [:]
            return Self.answer(id: id, result: result)
        default:
            return Self.answer(id: id, error: (-32601, "Method not found"))
        }
    }

    private static func answer(id: Any, result: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])) ?? Data()
    }

    private static func answer(id: Any, error: (code: Int, message: String)) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
            "error": ["code": error.code, "message": error.message]])) ?? Data()
    }

    private actor Output {
        let handle: FileHandle
        init(handle: FileHandle) { self.handle = handle }
        func write(_ data: Data) { handle.write(data + Data("\n".utf8)) }
    }
}
