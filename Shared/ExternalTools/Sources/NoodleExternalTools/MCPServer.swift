import Darwin
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

    /// Serves until standard input closes. Calls run side by side; answers are written whole. On its own standard
    /// input and output, the server hands itself over to a new executable an update put in its place.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        let stdio = input.fileDescriptor == STDIN_FILENO && output.fileDescriptor == STDOUT_FILENO
        var resume: MCPRelaunch.Resume?
        if stdio {
            resume = MCPRelaunch.resume(from: ProcessInfo.processInfo.environment)
            unsetenv(MCPRelaunch.environmentKey)
        }
        await run(input: input, output: output, relaunch: stdio ? MCPRelaunch.current() : nil, resume: resume)
    }

    /// `resume` is what the process this one replaced handed over.
    func run(input: FileHandle, output sink: FileHandle, relaunch: MCPRelaunch?, resume: MCPRelaunch.Resume?) async {
        let output = Output(handle: sink)
        var relaunch = relaunch
        var protocolVersion = resume?.protocolVersion
        // Read here rather than through FileHandle.bytes, so whatever was read and not yet answered can be handed over.
        var buffer = resume?.pending.map(MCPRelaunch.unstash) ?? Data()
        await withTaskGroup(of: Void.self) { group in
            var ended = false
            while true {
                // Only a newline ends a message: Foundation's lines also break at U+2028, U+2029 and U+0085,
                // which JSON may carry unescaped inside a string.
                while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let message = Data(buffer[buffer.startIndex..<end])
                    guard !message.isEmpty else { buffer = Data(buffer[(end + 1)...]); continue }
                    if let current = relaunch, current.changed {
                        // The calls already running are answered from here; the new executable takes the rest.
                        await group.waitForAll()
                        let failure = current.takeOver(pending: buffer, protocolVersion: protocolVersion)
                        FileHandle.standardError.write(Data("\(name): could not run the updated tool: \(failure)\n".utf8))
                        relaunch = nil
                    }
                    buffer = Data(buffer[(end + 1)...])
                    if let version = Self.negotiated(message) { protocolVersion = version }
                    group.addTask { if let answer = await handle(message) { await output.write(answer) } }
                }
                if ended { break }
                let chunk = await Self.read(input)
                if chunk.isEmpty {
                    // The last message may end without a newline.
                    ended = true
                    if !buffer.isEmpty { buffer.append(UInt8(ascii: "\n")) }
                } else {
                    buffer.append(chunk)
                }
            }
        }
    }

    /// What arrived next, or nothing once the input closed. One read at a time, only when the server asks for it,
    /// so nothing is read that a hand-over would lose.
    private static func read(_ input: FileHandle) async -> Data {
        let descriptor = input.fileDescriptor
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var count: Int
                repeat { count = Darwin.read(descriptor, &buffer, buffer.count) } while count < 0 && errno == EINTR
                continuation.resume(returning: count > 0 ? Data(buffer[..<count]) : Data())
            }
        }
    }

    /// The version an initialize request settles on.
    static func negotiated(_ message: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              object["method"] as? String == "initialize", object["id"] != nil else { return nil }
        return agreedVersion(asked: (object["params"] as? [String: Any])?["protocolVersion"] as? String)
    }

    private static func agreedVersion(asked: String?) -> String {
        asked.flatMap { versions.contains($0) ? $0 : nil } ?? versions.last!
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
            return Self.answer(id: id, result: [
                "protocolVersion": Self.agreedVersion(asked: params["protocolVersion"] as? String),
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
