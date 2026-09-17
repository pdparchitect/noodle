import BrowserBridge
import Foundation

public struct BrowserAssignments: Codable, Sendable {
    public var version = 1
    public var browsers: [RemoteBrowser] = []
    public var agents: [String: Set<UUID>] = [:]
    public init() {}
    public func assigned(to agent: UUID) -> Set<UUID> { agents[agent.uuidString] ?? [] }
    public func permits(_ browser: UUID?, agent: UUID) -> Bool { browser.map { assigned(to: agent).contains($0) } ?? false }
    public static func load(root: URL) throws -> Self {
        let url = root.appendingPathComponent("browsers.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: MCPBridgeFiles.read(url, limit: 8 * 1_048_576))
        guard value.version == 1 else { throw BrowserError("Unsupported browser assignments. Existing settings were not changed.") }
        return value
    }
    public func save(root: URL) throws { try MCPBridgeFiles.write(self, to: root.appendingPathComponent("browsers.json")) }
}
public struct BrowserAgentRequest: Codable, Sendable {
    public var id = UUID()
    public var token: String
    public var request: BrowserRequest
    public var localPath: String?
    public var conversationID: UUID?
    public var message: String?
    public var expiresAt: Date
    public init(token: String, request: BrowserRequest, localPath: String? = nil) {
        self.token = token; self.request = request; self.localPath = localPath
        expiresAt = Date().addingTimeInterval(Double(request.operation.timeout))
    }
}
public enum BrowserAgentSkill {
    public static var instructions: String { MessengerDocumentation.browserSkill }
    public static func synchronize(workspace: URL, enabled: Bool, executable: URL?) throws {
        try WorkspaceMailbox.synchronizeSkill(workspace: workspace, name: "browser", enabled: enabled,
            instructions: instructions, command: "browser", executable: executable)
    }
    public static func bridge(workspace: URL) throws -> URL {
        try WorkspaceMailbox(workspace: workspace, path: ".noodle/browser-bridge", create: true).url
    }
}
