import Foundation
import Darwin

public enum MCPBridgeAction: String, Codable, Sendable { case tools, inspect, call }
public struct MCPBridgeRequest: Codable, Sendable {
    public let id: UUID
    public let session: String
    public let connectionID: UUID?
    public let skillName: String?
    public let action: MCPBridgeAction
    public let tool: String?
    public let arguments: Data?
    public let expiresAt: Date
    public init(id: UUID = UUID(), session: String, connectionID: UUID? = nil, skillName: String? = nil, action: MCPBridgeAction,
                tool: String?, arguments: Data?, expiresAt: Date = Date().addingTimeInterval(120)) {
        self.id = id; self.session = session; self.connectionID = connectionID
        self.skillName = skillName
        self.action = action; self.tool = tool; self.arguments = arguments; self.expiresAt = expiresAt
    }

    /// Called by the broker with its own assignment list, never a CLI-supplied registry.
    public func assignedConnection(in assignments: [MCPConnectionRecord]) -> MCPConnectionRecord? {
        guard (connectionID != nil) != (skillName != nil) else { return nil }
        if let connectionID { return assignments.first { $0.id == connectionID } }
        return assignments.first { $0.skillName == skillName }
    }
}
public struct MCPBridgeSession: Codable, Sendable {
    public let token: String
    public let processID: Int32
    public init(token: String, processID: Int32) { self.token = token; self.processID = processID }
}
public struct MCPBridgeResponse: Codable, Sendable {
    public let result: Data?
    public let error: String?
    public init(result: Data? = nil, error: String? = nil) { self.result = result; self.error = error }
}

/// File IPC works inside the existing workspace sandbox, including harnesses with
/// networking disabled. Only app-created per-agent session capabilities are accepted.
/// No OAuth credentials are ever written here. This is not isolation from full-access bots.
public enum MCPBridgeFiles {
    public static let maxRequestBytes = 1_048_576
    // JSON encodes the argument bytes as base64; allow that overhead separately.
    public static let maxRequestEnvelopeBytes = (maxRequestBytes + 2) / 3 * 4 + 4096
    public static let maxResponseBytes = 16 * 1_048_576
    public static func directory(workspace: URL) -> URL {
        workspace.appendingPathComponent(".noodle/mcp-bridge", isDirectory: true)
    }
    public static func prepare(workspace: URL) throws -> URL {
        try WorkspaceMailbox(workspace: workspace, path: ".noodle/mcp-bridge", create: true).url
    }
    public static func read(_ file: URL, limit: Int, workspace: URL? = nil) throws -> Data {
        if let workspace { return try mailbox(for: file, workspace: workspace).read(file.lastPathComponent, limit: limit) }
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(.ENOENT) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= limit else { throw MCPConnectionError.message("Invalid MCP bridge file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw MCPConnectionError.message("MCP request or response is too large.") }
        return data
    }
    public static func write<T: Encodable>(_ value: T, to file: URL, workspace: URL? = nil) throws {
        if let workspace { try mailbox(for: file, workspace: workspace).write(value, named: file.lastPathComponent); return }
        let data = try JSONEncoder().encode(value)
        // Atomic replacement replaces a link itself, never follows its target.
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static func mailbox(for file: URL, workspace: URL) throws -> WorkspaceMailbox {
        // Foundation directory listings can switch /var to /private/var. Normalize
        // only these system aliases; never resolve bot-controlled parent links.
        func path(_ url: URL) -> String {
            let value = url.standardizedFileURL.path
            for alias in ["/var", "/tmp", "/etc"] where value == alias || value.hasPrefix(alias + "/") {
                return "/private" + value
            }
            return value
        }
        let prefix = path(workspace) + "/"
        let parent = path(file.deletingLastPathComponent())
        guard parent.hasPrefix(prefix) else { throw MCPConnectionError.message("Bridge files must stay inside the bot workspace.") }
        return try WorkspaceMailbox(workspace: workspace, path: String(parent.dropFirst(prefix.count)))
    }
}
