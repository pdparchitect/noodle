import Darwin
import Foundation

public enum ToolBridgeAction: String, Codable, Sendable { case providers, tools, inspect, call }

/// One agent request for any tool provider. The app authenticates `session`,
/// resolves the agent's assignments and answers through `ToolBroker`.
public struct ToolBridgeRequest: Codable, Sendable {
    public let id: UUID
    public let session: String
    public let action: ToolBridgeAction
    public let provider: String?
    public let tool: String?
    public let arguments: Data?
    /// Workspace-relative directory the command ran in; file arguments resolve against it.
    public let currentDirectory: String
    public let expiresAt: Date
    public init(id: UUID = UUID(), session: String, action: ToolBridgeAction, provider: String? = nil, tool: String? = nil,
                arguments: Data? = nil, currentDirectory: String = "", expiresAt: Date = Date().addingTimeInterval(120)) {
        self.id = id; self.session = session; self.action = action; self.provider = provider; self.tool = tool
        self.arguments = arguments; self.currentDirectory = currentDirectory; self.expiresAt = expiresAt
    }
}

public typealias ToolBridgeResponse = MCPBridgeResponse

public enum ToolBroker {
    public static let path = ".noodle/tool-bridge"
    public static let defaultTimeout: TimeInterval = 120

    /// The caller gets an answer at the deadline even when the provider cannot be cancelled.
    static func withTimeout(_ seconds: TimeInterval, tool: String, _ work: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let task = Task {
                do { let value = try await work(); if once.claim() { continuation.resume(returning: value) } }
                catch { if once.claim() { continuation.resume(throwing: error) } }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard once.claim() else { return }
                task.cancel()
                continuation.resume(throwing: ToolProviderError("\(tool) timed out after \(Int(seconds)) seconds. Verify any action before retrying."))
            }
        }
    }
    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var claimed = false
        func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }
    }

    /// Provider-independent dispatch. `assignments` must already reflect what the
    /// host granted this agent; nothing in the request can widen them.
    public static func perform(_ request: ToolBridgeRequest, registry: ToolProviderRegistry, assignments: Set<String>,
                               context: ToolCallContext) async throws -> Data {
        if request.action == .providers {
            guard request.provider == nil, request.tool == nil, request.arguments == nil else { throw ToolProviderError("Invalid tool request.") }
            let kinds = registry.kinds()
            let providers = registry.manifests(assignments: assignments).map {
                ["id": $0.id, "title": $0.title, "summary": $0.summary, "kind": kinds[$0.id]?.rawValue ?? ""]
            }
            return try JSONSerialization.data(withJSONObject: ["providers": providers], options: [.sortedKeys])
        }
        guard let id = request.provider, (request.tool != nil) == (request.action != .tools),
              request.action == .call || request.arguments == nil else { throw ToolProviderError("Invalid tool request.") }
        let provider = try registry.provider(id, assignments: assignments)
        let list = try await provider.tools(context: context)
        if request.action == .tools { _ = try ToolDescriptor.list(mcp: list); return list }
        guard let descriptor = try ToolDescriptor.list(mcp: list).first(where: { $0.name == request.tool }) else {
            throw ToolProviderError("The \(id) provider has no tool named \(request.tool ?? "").")
        }
        if request.action == .inspect {
            let tools = (try JSONSerialization.jsonObject(with: list) as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            return try JSONSerialization.data(withJSONObject: tools.first { $0["name"] as? String == descriptor.name } ?? [:], options: [.sortedKeys])
        }
        let arguments = request.arguments ?? Data("{}".utf8)
        let directory = request.currentDirectory.isEmpty ? context.workspace
            : context.workspace.appendingPathComponent(try ComputerWorkspaceFiles.relativePath(
                request.currentDirectory, currentDirectory: context.workspace, workspace: context.workspace))
        let files = try ToolFileArguments.open(descriptor, arguments: arguments, currentDirectory: directory, workspace: context.workspace)
        var succeeded = false
        defer {
            for file in files {
                try? file.handle.close()
                // A failed call must not leave the empty file the broker created for it.
                if !succeeded, file.access == .write { ToolFileArguments.discard(file, workspace: context.workspace) }
            }
        }
        let result = try await withTimeout(descriptor.timeout ?? defaultTimeout, tool: descriptor.name) {
            try await provider.call(descriptor.name, arguments: arguments, files: files, context: context)
        }
        succeeded = (try? JSONSerialization.jsonObject(with: result) as? [String: Any])?["isError"] as? Bool != true
        return result
    }
}
