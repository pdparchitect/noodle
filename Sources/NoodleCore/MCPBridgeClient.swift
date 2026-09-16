import Foundation
import Darwin

/// Synchronous workspace transport shared by ordinary CLI commands and scripts.
/// The app remains responsible for authorizing every individual request.
public struct MCPBridgeClient {
    public let context: MCPInvocationContext
    public let currentDirectory: URL
    public let connectionID: UUID?
    public let deadline: TimeInterval?

    public init(context: MCPInvocationContext, currentDirectory: URL, connectionID: UUID? = nil,
                deadline: TimeInterval? = nil) throws {
        guard connectionID != nil || context.skillName != nil else {
            throw MCPConnectionError.message("Use the mcpshim inside the relevant skill directory so Noodle can select its connection.")
        }
        guard context.skillName == nil || connectionID == nil else {
            throw MCPConnectionError.message("A skill-local mcpshim selects its own connection. Omit --connection.")
        }
        self.context = context
        self.currentDirectory = currentDirectory
        self.connectionID = connectionID
        self.deadline = deadline
    }

    public func perform(_ action: MCPBridgeAction, tool: String? = nil, arguments: Data? = nil,
                        uri: String? = nil, raw: Bool = false) throws -> Data {
        let needsTool = action == .inspect || action == .call
        guard needsTool ? !(tool ?? "").isEmpty : tool == nil,
              (tool?.utf8.count ?? 0) <= 1024,
              action == .call || arguments == nil,
              action == .readResource ? !(uri ?? "").isEmpty : uri == nil,
              (uri?.utf8.count ?? 0) <= 4096,
              !raw || action == .call || action == .readResource else {
            throw MCPConnectionError.message("Invalid MCP operation arguments.")
        }
        let remaining = (deadline ?? .infinity) - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw MCPConnectionError.message("MCP script timed out. Verify any remote action before retrying.") }
        let folder = try MCPBridgeFiles.prepare(workspace: context.workspace)
        let session: MCPBridgeSession
        do {
            session = try JSONDecoder().decode(MCPBridgeSession.self,
                from: MCPBridgeFiles.read(folder.appendingPathComponent("session.json"), limit: 4096, workspace: context.workspace))
        } catch { throw MCPConnectionError.message("Noodle's MCP bridge is not available. Open Noodle first.") }
        guard Self.isRunning(session.processID) else { throw MCPConnectionError.message("Noodle is not running. Open Noodle first.") }
        let input = action == .call
            ? try MCPFileContent.arguments(arguments ?? Data("{}".utf8), workspace: context.workspace, currentDirectory: currentDirectory)
            : nil
        let request = MCPBridgeRequest(session: session.token, connectionID: connectionID, skillName: context.skillName,
            action: action, tool: tool, arguments: input, uri: uri,
            expiresAt: Date().addingTimeInterval(min(120, (deadline ?? .infinity) - ProcessInfo.processInfo.systemUptime)))
        guard request.expiresAt > Date() else { throw MCPConnectionError.message("MCP script timed out. Verify any remote action before retrying.") }
        let stem = request.id.uuidString.lowercased()
        let requestFile = folder.appendingPathComponent(stem + ".request")
        let responseFile = folder.appendingPathComponent(stem + ".response")
        try MCPBridgeFiles.write(request, to: requestFile, workspace: context.workspace)
        defer {
            try? FileManager.default.removeItem(at: requestFile)
            try? FileManager.default.removeItem(at: responseFile)
        }
        let callDeadline = min(deadline ?? .infinity, ProcessInfo.processInfo.systemUptime + 125)
        while ProcessInfo.processInfo.systemUptime < callDeadline {
            if let data = try? MCPBridgeFiles.read(responseFile, limit: MCPBridgeFiles.maxResponseBytes + 4096, workspace: context.workspace) {
                let response = try JSONDecoder().decode(MCPBridgeResponse.self, from: data)
                if let error = response.error { throw MCPConnectionError.message(error) }
                guard let result = response.result else { throw MCPConnectionError.message("Empty MCP bridge response.") }
                guard result.count <= MCPBridgeFiles.maxResultBytes else { throw MCPConnectionError.message("MCP result exceeds 8 MiB.") }
                if action == .call || action == .readResource {
                    do {
                        return try MCPFileContent.result(result, workspace: context.workspace, callID: request.id,
                            raw: raw, resourceRead: action == .readResource)
                    } catch {
                        throw MCPConnectionError.message("Could not prepare MCP result files: \(error.localizedDescription) The remote request has already completed; verify any remote changes before retrying.")
                    }
                }
                return result
            }
            guard Self.isRunning(session.processID) else {
                throw MCPConnectionError.message("Noodle stopped during the request. Verify any remote action before retrying.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw MCPConnectionError.message("MCP request timed out. Verify any remote action before retrying.")
    }

    private static func isRunning(_ processID: Int32) -> Bool {
        processID > 0 && (kill(processID, 0) == 0 || errno == EPERM)
    }
}
