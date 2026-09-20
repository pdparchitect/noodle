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

    /// Provider-independent dispatch. `assignments` reads what the host currently grants
    /// this agent; it is read again after a call, and nothing in the request can widen it.
    public static func perform(_ request: ToolBridgeRequest, registry: ToolProviderRegistry,
                               assignments current: @escaping @Sendable () -> ToolAssignments,
                               context base: ToolCallContext, host: ToolHostServices = .none) async throws -> Data {
        let assignments = current()
        let context = ToolCallContext(agentID: base.agentID, workspace: base.workspace, assignments: assignments)
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
            var tool = tools.first { $0["name"] as? String == descriptor.name } ?? [:]
            // The command line treats a connection's arguments differently; see ToolCLI.
            tool["_meta"] = (tool["_meta"] as? [String: Any] ?? [:]).merging(["noodle/kind": provider.kind.rawValue]) { $1 }
            return try JSONSerialization.data(withJSONObject: tool, options: [.sortedKeys])
        }
        let (authorized, used) = try authorize(descriptor, provider: provider.manifest, arguments: request.arguments ?? Data("{}".utf8),
                                               assignments: assignments)
        let (arguments, conversation) = try conversation(descriptor, arguments: authorized, agent: context.agentID, host: host)
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
        let revoked = ToolProviderError("This \(used.first?.kind ?? "resource") is no longer assigned to this bot. The action may already have happened.")
        let stillAllowed: @Sendable () -> Bool = { [used] in
            let latest = current()
            return used.allSatisfy { latest.assigned($0.id, kind: $0.kind) != nil } && registry.manifests(assignments: latest).contains { $0.id == id }
        }
        let checked = ToolCallContext(agentID: context.agentID, workspace: context.workspace, assignments: assignments,
                                      authorize: { [conversation] in
            guard stillAllowed(), conversation.map({ host.isMember(context.agentID, $0) }) != false else { throw revoked }
        })
        let outcome: Result<Data, Error>
        do {
            outcome = .success(try await withTimeout(descriptor.timeout ?? defaultTimeout, tool: descriptor.name) {
                try await provider.call(descriptor.name, arguments: arguments, files: files, context: checked)
            })
        } catch { outcome = .failure(error) }
        // A resource unassigned while the call ran must not deliver its result or its files.
        // This holds whether the provider returned, failed, or stopped at its own checkpoint.
        let latest = current()
        guard stillAllowed() else {
            for resource in used where latest.assigned(resource.id, kind: resource.kind) == nil { host.revoked(resource.kind, resource.id, context.agentID) }
            throw revoked
        }
        let result = try outcome.get()
        let filtered = try post(filter(result, descriptor: descriptor, assignments: latest), descriptor: descriptor,
                                conversation: conversation, agent: context.agentID, host: host)
        succeeded = (try? JSONSerialization.jsonObject(with: filtered) as? [String: Any])?["isError"] as? Bool != true
        return filtered
    }

    /// Verifies every declared resource argument and re-encodes what was verified, so the
    /// provider can never read a different identifier out of the same bytes.
    static func authorize(_ descriptor: ToolDescriptor, provider: ToolProviderManifest, arguments: Data,
                          assignments: ToolAssignments) throws -> (Data, [(kind: String, id: String)]) {
        guard var object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw ToolProviderError("Tool arguments must be a JSON object.")
        }
        if let missing = descriptor.required.first(where: { object[$0] == nil || object[$0] is NSNull }) {
            throw ToolProviderError("The \(descriptor.name) tool needs --\(missing).")
        }
        var used: [(kind: String, id: String)] = []
        for parameter in descriptor.resourceParameters {
            guard let value = object[parameter.name] else { continue }
            guard let id = value as? String, let assigned = assignments.assigned(id, kind: parameter.kind) else {
                throw ToolProviderError("This \(parameter.kind) is not assigned to you.")
            }
            object[parameter.name] = assigned
            used.append((parameter.kind, assigned))
        }
        // Fail closed: a provider that exists because of an assignment may only run tools
        // that say which assigned resource they act on, or that list them for filtering.
        if let kind = provider.activation.resource, descriptor.resourceList?.kind != kind, !used.contains(where: { $0.kind == kind }) {
            throw ToolProviderError(descriptor.resourceParameters.contains { $0.kind == kind }
                ? "Specify which assigned \(kind) to use."
                : "The \(descriptor.name) tool does not declare which \(kind) it uses, so Noodle will not run it.")
        }
        return (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), used)
    }

    /// Verifies a declared conversation argument the same way as a resource: refuse before
    /// the provider runs, and forward the canonical spelling.
    static func conversation(_ descriptor: ToolDescriptor, arguments: Data, agent: UUID, host: ToolHostServices) throws -> (Data, UUID?) {
        guard let name = descriptor.conversationParameter, var object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              let value = object[name] else { return (arguments, nil) }
        guard let id = (value as? String).flatMap(UUID.init(uuidString:)), host.isMember(agent, id) else {
            throw ToolProviderError("You are not a participant in that conversation.")
        }
        object[name] = id.uuidString
        return (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), id)
    }

    /// Consumes `_meta["noodle/post"]`. Only a verified conversation can receive it, and
    /// membership is read again because the call may have taken minutes.
    static func post(_ result: Data, descriptor: ToolDescriptor, conversation: UUID?, agent: UUID, host: ToolHostServices) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: result) as? [String: Any], var meta = object["_meta"] as? [String: Any],
              let requested = meta["noodle/post"] else { return result }
        if object["isError"] as? Bool == true { return result }
        guard let conversation, let payload = requested as? [String: Any] else {
            throw ToolProviderError("The \(descriptor.name) tool tried to post without a conversation Noodle verified.")
        }
        let post = try ToolPost(payload)
        guard host.isMember(agent, conversation) else { throw ToolProviderError("You are no longer a participant in that conversation.") }
        let attachment = try host.post(post, agent, conversation)
        meta["noodle/post"] = nil
        object["_meta"] = meta.isEmpty ? nil : meta
        var structured = object["structuredContent"] as? [String: Any] ?? [:]
        structured["attachmentID"] = attachment.uuidString
        object["structuredContent"] = structured
        let text = String(decoding: try JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]), as: UTF8.self)
        object["content"] = [["type": "text", "text": text]]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Removes unassigned entries from a declared resource list and rebuilds the text
    /// from what remains, so nothing about other resources reaches the bot.
    static func filter(_ result: Data, descriptor: ToolDescriptor, assignments: ToolAssignments) throws -> Data {
        guard let list = descriptor.resourceList else { return result }
        guard var object = try JSONSerialization.jsonObject(with: result) as? [String: Any] else {
            throw ToolProviderError("The \(descriptor.name) tool returned an invalid result.")
        }
        if object["isError"] as? Bool == true { return result }
        guard var structured = object["structuredContent"] as? [String: Any], let entries = structured[list.path] as? [[String: Any]] else {
            throw ToolProviderError("The \(descriptor.name) tool did not return its \(list.kind) list in a form Noodle can filter.")
        }
        let permitted = entries.filter { ($0["id"] as? String).flatMap { assignments.assigned($0, kind: list.kind) } != nil }
        structured = [list.path: permitted]
        object["structuredContent"] = structured
        let text = String(decoding: try JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self)
        object["content"] = [["type": "text", "text": text]]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
