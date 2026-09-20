import Darwin
import Foundation

/// One contract for every agent tool source: built-in commands, MCP connections
/// and bundled app extensions. Tool payloads stay MCP-shaped (`tools/list`,
/// `tools/call`) so every kind shares one agent-facing format.
public enum ToolProviderKind: String, Codable, Sendable { case builtIn, connection, appExtension = "extension" }

public struct ToolProviderError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// `always`, or `assigned:RESOURCE` for providers that follow a per-agent assignment.
public struct ToolActivation: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let always = Self(rawValue: "always")
    public static func whenAssigned(_ resource: String) -> Self { Self(rawValue: "assigned:" + resource) }
    public var resource: String? { rawValue.hasPrefix("assigned:") ? String(rawValue.dropFirst(9)) : nil }
    /// `granted:KIND/ID`: the provider itself is what Noodle assigns, such as one tool
    /// connection. Its tools name no resource; the grant is checked around every call.
    public static func whenGranted(_ kind: String, id: String) -> Self { Self(rawValue: "granted:\(kind)/\(id)") }
    public var grant: (kind: String, id: String)? {
        guard rawValue.hasPrefix("granted:") else { return nil }
        let parts = rawValue.dropFirst(8).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty ? (String(parts[0]), String(parts[1])) : nil
    }
    var isValid: Bool { self == .always || !(resource ?? "").isEmpty || grant != nil }
    var isValidForTesting: Bool { isValid }
}

/// What Noodle granted one bot: resource kind (such as `browser`) to the identifiers it may use.
/// Only the app builds this, from its own stores; nothing in a request can add to it.
public struct ToolAssignments: Codable, Equatable, Sendable, ExpressibleByDictionaryLiteral {
    public var resources: [String: Set<String>]
    public init(_ resources: [String: Set<String>] = [:]) { self.resources = resources }
    public init(dictionaryLiteral elements: (String, Set<String>)...) { resources = Dictionary(elements) { $0.union($1) } }
    public static let none = ToolAssignments()
    public func ids(_ kind: String) -> Set<String> { resources[kind] ?? [] }
    /// The assigned spelling of `id`, matched without case so UUIDs compare as UUIDs.
    public func assigned(_ id: String, kind: String) -> String? {
        id.isEmpty ? nil : ids(kind).first { $0.caseInsensitiveCompare(id) == .orderedSame }
    }
}

/// Lets the broker report a mid-call revocation to controllers created after it.
public final class ToolRevocations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable (String, String, UUID) -> Void)?
    public init() {}
    public var handler: (@Sendable (String, String, UUID) -> Void)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    public func handle(_ kind: String, _ id: String, _ agent: UUID) { handler?(kind, id, agent) }
}

/// The app's live picture of every bot's assignments, readable from the broker's queue.
/// Each controller replaces its own kind whenever its registry changes.
public final class ToolAssignmentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [String: [UUID: Set<String>]] = [:]
    public init() {}
    public func replace(_ kind: String, with assigned: [UUID: Set<String>]) {
        lock.withLock { kinds[kind] = assigned.filter { !$0.value.isEmpty } }
    }
    public func assignments(for agent: UUID) -> ToolAssignments {
        lock.withLock { ToolAssignments(kinds.compactMapValues { $0[agent] }) }
    }
}

/// Something a tool asks Noodle to post as the calling bot: one attachment and its message.
public struct ToolPost: Sendable, Equatable {
    public static let maximumBytes = 32 * 1_048_576
    public let message: String?
    public let filename: String
    public let mediaType: String
    public let data: Data

    /// Reads `_meta["noodle/post"]`. Anything malformed is an error, never a partial post.
    init(_ object: [String: Any]) throws {
        guard let attachment = object["attachment"] as? [String: Any],
              let filename = attachment["filename"] as? String, !filename.isEmpty, filename.utf8.count <= 255,
              !filename.contains("/"), !filename.utf8.contains(0), filename != ".", filename != "..",
              let mediaType = attachment["mediaType"] as? String, !mediaType.isEmpty, mediaType.utf8.count <= 255,
              let encoded = attachment["data"] as? String, let data = Data(base64Encoded: encoded), data.count <= Self.maximumBytes else {
            throw ToolProviderError("The tool returned an attachment Noodle cannot post.")
        }
        message = (object["message"] as? String).map { String($0.prefix(10_000)) }
        self.filename = filename; self.mediaType = mediaType; self.data = data
    }
}

/// What only the app can do for a tool. Extensions never receive these; the broker
/// calls them after its own checks.
public struct ToolHostServices: Sendable {
    public let isMember: @Sendable (_ agent: UUID, _ conversation: UUID) -> Bool
    /// Posts as the bot and returns the new attachment's ID.
    public let post: @Sendable (_ post: ToolPost, _ agent: UUID, _ conversation: UUID) throws -> UUID
    /// A resource was unassigned while a call used it. The result was withheld; the app can
    /// now undo what the call may have started, such as closing the bot's terminals.
    public let revoked: @Sendable (_ kind: String, _ id: String, _ agent: UUID) -> Void
    public init(isMember: @escaping @Sendable (UUID, UUID) -> Bool, post: @escaping @Sendable (ToolPost, UUID, UUID) throws -> UUID,
                revoked: @escaping @Sendable (String, String, UUID) -> Void = { _, _, _ in }) {
        self.isMember = isMember; self.post = post; self.revoked = revoked
    }
    public static let none = ToolHostServices(isMember: { _, _ in false }, post: { _, _, _ in throw ToolProviderError("This Noodle cannot post for tools.") })
}

/// What a provider declares about itself. Extensions send this as JSON.
public struct ToolProviderManifest: Codable, Equatable, Sendable, Identifiable {
    public var version = 1
    /// Agent-facing name and skill folder: lowercase letters, digits and hyphens.
    public let id: String
    public let title: String
    public let summary: String
    /// Provider-level guidance that per-tool descriptions cannot carry.
    public let instructions: String
    public let activation: ToolActivation
    public init(id: String, title: String, summary: String, instructions: String = "", activation: ToolActivation = .always) {
        self.id = id; self.title = title; self.summary = summary; self.instructions = instructions; self.activation = activation
    }
    public func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard version == 1, !id.isEmpty, id.utf8.count <= 48, id.first != "-", id.last != "-",
              id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ToolProviderError("Tool provider names use up to 48 lowercase letters, digits and hyphens.")
        }
        guard !title.isEmpty, title.utf8.count <= 128, summary.utf8.count <= 1024,
              instructions.utf8.count <= 65_536, activation.isValid else {
            throw ToolProviderError("The \(id) tool provider has an invalid manifest.")
        }
    }
}

/// A schema property with `"format": "noodle-file"` is a workspace path. The broker
/// opens it and hands the provider a descriptor; providers never see the workspace.
public struct ToolFileParameter: Equatable, Sendable {
    public enum Access: String, Sendable { case read, write }
    public let name: String
    public let access: Access
    public init(name: String, access: Access) { self.name = name; self.access = access }
}

/// A schema property with `"format": "noodle-resource"` names an assigned resource of
/// `"noodle/kind"`. The broker refuses any value the bot was not assigned.
public struct ToolResourceParameter: Equatable, Sendable {
    public let name: String
    public let kind: String
    public init(name: String, kind: String) { self.name = name; self.kind = kind }
}

/// `_meta["noodle/resource-list"]`: the result lists resources of `kind` as objects
/// with an `id` under `structuredContent[path]`. The broker removes unassigned entries.
public struct ToolResourceList: Equatable, Sendable {
    public let kind: String
    public let path: String
    public init(kind: String, path: String) { self.kind = kind; self.path = path }
}

public struct ToolDescriptor: Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: Data
    public let fileParameters: [ToolFileParameter]
    public let resourceParameters: [ToolResourceParameter]
    public let resourceList: ToolResourceList?
    /// A property with `"format": "noodle-conversation"`. The broker refuses conversations the
    /// bot is not in, and only such a tool may return something for Noodle to post there.
    public let conversationParameter: String?
    /// The schema's `required` names. The broker refuses a call that omits one.
    public let required: [String]
    /// `_meta["noodle/timeout"]`, clamped to 1–3600 seconds.
    public let timeout: TimeInterval?
    /// MCP `annotations.idempotentHint`. Absent means a timed-out call must not be repeated.
    public let retryable: Bool

    public init(mcp object: [String: Any]) throws {
        guard let name = object["name"] as? String, !name.isEmpty, name.utf8.count <= 1024 else {
            throw ToolProviderError("A tool is missing its name.")
        }
        let schema = object["inputSchema"] as? [String: Any] ?? ["type": "object"]
        self.name = name
        description = object["description"] as? String ?? ""
        inputSchema = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        fileParameters = try ((schema["properties"] as? [String: Any]) ?? [:]).sorted { $0.key < $1.key }.compactMap { key, value in
            guard let property = value as? [String: Any], property["format"] as? String == "noodle-file" else { return nil }
            guard let access = ToolFileParameter.Access(rawValue: property["noodle/access"] as? String ?? "read") else {
                throw ToolProviderError("The \(name) tool declares an unknown file access for \(key).")
            }
            return ToolFileParameter(name: key, access: access)
        }
        resourceParameters = try ((schema["properties"] as? [String: Any]) ?? [:]).sorted { $0.key < $1.key }.compactMap { key, value in
            guard let property = value as? [String: Any], property["format"] as? String == "noodle-resource" else { return nil }
            guard let kind = property["noodle/kind"] as? String, !kind.isEmpty else {
                throw ToolProviderError("The \(name) tool does not say which kind of resource \(key) names.")
            }
            return ToolResourceParameter(name: key, kind: kind)
        }
        required = schema["required"] as? [String] ?? []
        conversationParameter = ((schema["properties"] as? [String: Any]) ?? [:]).sorted { $0.key < $1.key }
            .first { ($0.value as? [String: Any])?["format"] as? String == "noodle-conversation" }?.key
        let listed = (object["_meta"] as? [String: Any])?["noodle/resource-list"] as? [String: Any]
        resourceList = try listed.map {
            guard let kind = $0["kind"] as? String, let path = $0["path"] as? String, !kind.isEmpty, !path.isEmpty else {
                throw ToolProviderError("The \(name) tool has an invalid resource list declaration.")
            }
            return ToolResourceList(kind: kind, path: path)
        }
        timeout = ((object["_meta"] as? [String: Any])?["noodle/timeout"] as? Double).map { min(max($0, 1), 3600) }
        retryable = (object["annotations"] as? [String: Any])?["idempotentHint"] as? Bool ?? false
    }

    public static func list(mcp data: Data) throws -> [ToolDescriptor] {
        guard let tools = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tools"] as? [[String: Any]] else {
            throw ToolProviderError("The tool provider returned an invalid tool list.")
        }
        return try tools.map(ToolDescriptor.init(mcp:))
    }
}

public struct ToolCallContext: Sendable {
    public let agentID: UUID
    public let workspace: URL
    /// The calling bot's assignments, for providers that list or describe resources.
    /// Authorization never depends on a provider reading this; the broker enforces it.
    public let assignments: ToolAssignments
    /// A checkpoint for slow calls. Ask just before a step that cannot be undone, such as
    /// sending a command or a staged upload: Noodle answers from the bot's live assignments
    /// and throws if the call is no longer allowed. The decision is never the provider's.
    public let authorize: @Sendable () async throws -> Void
    public init(agentID: UUID, workspace: URL, assignments: ToolAssignments = .none,
                authorize: @escaping @Sendable () async throws -> Void = {}) {
        self.agentID = agentID; self.workspace = workspace; self.assignments = assignments; self.authorize = authorize
    }
}

/// An opened workspace file for one declared file parameter.
public struct ToolFile: @unchecked Sendable {
    public let parameter: String
    public let access: ToolFileParameter.Access
    public let handle: FileHandle
    /// Workspace-relative path the broker opened. Providers receive the handle, not this.
    public let path: String
    public init(parameter: String, access: ToolFileParameter.Access, handle: FileHandle, path: String = "") {
        self.parameter = parameter; self.access = access; self.handle = handle; self.path = path
    }
}

public protocol ToolProvider: Sendable {
    var kind: ToolProviderKind { get }
    var manifest: ToolProviderManifest { get }
    /// MCP `tools/list` result JSON.
    func tools(context: ToolCallContext) async throws -> Data
    /// MCP `tools/call` result JSON.
    func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data
}

/// Discovery writes here; brokers and skill generation read. Authorization stays with
/// the caller: `assignments` are the resources the host granted this agent.
public final class ToolProviderRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [String: any ToolProvider] = [:]
    private var observer: (@Sendable () -> Void)?
    public init() {}

    /// Called after every registration or removal, outside the registry's lock.
    public func onChange(_ observer: (@Sendable () -> Void)?) { lock.withLock { self.observer = observer } }

    public func register(_ provider: any ToolProvider) throws {
        try provider.manifest.validate()
        try lock.withLock {
            guard providers[provider.manifest.id] == nil else {
                throw ToolProviderError("A tool provider named \(provider.manifest.id) is already registered.")
            }
            providers[provider.manifest.id] = provider
        }
        lock.withLock { observer }?()
    }

    public func unregister(_ id: String) {
        guard lock.withLock({ providers.removeValue(forKey: id) }) != nil else { return }
        lock.withLock { observer }?()
    }

    func active(assignments: ToolAssignments) -> [any ToolProvider] {
        lock.withLock { Array(providers.values) }.filter { Self.isActive($0.manifest.activation, assignments: assignments) }
            .sorted { $0.manifest.id < $1.manifest.id }
    }
    public func kinds() -> [String: ToolProviderKind] { lock.withLock { providers.mapValues(\.kind) } }

    public func manifests(assignments: ToolAssignments) -> [ToolProviderManifest] {
        lock.withLock { providers.values.map(\.manifest) }
            .filter { Self.isActive($0.activation, assignments: assignments) }.sorted { $0.id < $1.id }
    }

    public func provider(_ id: String, assignments: ToolAssignments) throws -> any ToolProvider {
        guard let provider = lock.withLock({ providers[id] }) else { throw ToolProviderError("There is no tool provider named \(id).") }
        guard Self.isActive(provider.manifest.activation, assignments: assignments) else {
            throw ToolProviderError("The \(id) tools are not assigned to this bot.")
        }
        return provider
    }

    static func isActive(_ activation: ToolActivation, assignments: ToolAssignments) -> Bool {
        activation == .always || activation.resource.map { !assignments.ids($0).isEmpty } == true
            || activation.grant.map { assignments.assigned($0.id, kind: $0.kind) != nil } == true
    }
}

public enum ToolFileArguments {
    /// Opens every declared file parameter present in `arguments`. Reads never follow
    /// links; writes create a new file and never replace an existing one.
    public static func open(_ descriptor: ToolDescriptor, arguments: Data, currentDirectory: URL, workspace: URL) throws -> [ToolFile] {
        guard let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw ToolProviderError("Tool arguments must be a JSON object.")
        }
        var files: [ToolFile] = []
        do {
            for parameter in descriptor.fileParameters {
                guard let value = object[parameter.name] else { continue }
                guard let path = value as? String else { throw ToolProviderError("\(parameter.name) must be a workspace file path.") }
                let relative = try ComputerWorkspaceFiles.relativePath(path, currentDirectory: currentDirectory, workspace: workspace)
                let (parent, name) = try ComputerWorkspaceFiles.parent(workspace: workspace, path: relative)
                defer { Darwin.close(parent) }
                let flags = parameter.access == .read ? O_RDONLY | O_NONBLOCK : O_WRONLY | O_CREAT | O_EXCL
                let fd = openat(parent, name, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
                var info = stat()
                guard fd >= 0, fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                    if fd >= 0 { Darwin.close(fd) }
                    throw ToolProviderError(parameter.access == .read
                        ? "Cannot read \(relative); expected a regular workspace file."
                        : "Cannot create \(relative); existing files are never replaced.")
                }
                files.append(ToolFile(parameter: parameter.name, access: parameter.access,
                                      handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true), path: relative))
            }
        } catch {
            files.forEach { try? $0.handle.close() }
            throw error
        }
        return files
    }

    /// Removes a file this broker created, through the same link-free descriptor walk.
    static func discard(_ file: ToolFile, workspace: URL) {
        guard file.access == .write, let (parent, name) = try? ComputerWorkspaceFiles.parent(workspace: workspace, path: file.path) else { return }
        unlinkat(parent, name, 0)
        Darwin.close(parent)
    }
}

/// Command-line sugar over a tool's input schema: `--name value` sets a declared
/// property with its schema type, and `--input JSON` seeds anything flags cannot express.
public enum ToolArguments {
    public static func build(_ flags: [String], schema: Data) throws -> Data {
        let properties = ((try? JSONSerialization.jsonObject(with: schema)) as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let valid = properties.isEmpty ? "--input JSON" : (["--input"] + properties.keys.sorted().map { "--" + $0 }).joined(separator: ", ")
        var object: [String: Any] = [:]
        var seed: [String: Any]?
        var seen: Set<String> = []
        var index = 0
        func next() -> String? { index + 1 < flags.count ? flags[index + 1] : nil }
        while index < flags.count {
            let flag = flags[index]
            if flag == "--input" {
                guard seed == nil, let raw = next(),
                      let value = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                    throw ToolProviderError("--input takes one JSON object.")
                }
                seed = value; index += 2
                continue
            }
            guard flag.hasPrefix("--"), let name = property(String(flag.dropFirst(2)), in: properties) else {
                throw ToolProviderError("Unknown option \(flag). Valid options: \(valid).")
            }
            let type = (properties[name] as? [String: Any])?["type"] as? String
            if type == "boolean" {
                let explicit = next().flatMap { ["true": true, "false": false][$0] }
                guard seen.insert(name).inserted else { throw ToolProviderError("\(flag) was given more than once.") }
                object[name] = explicit ?? true
                index += explicit == nil ? 1 : 2
                continue
            }
            guard let raw = next() else { throw ToolProviderError("\(flag) needs a value.") }
            let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
            if type == "array", !(json is [Any]) {
                // Repeating a flag builds a list of plain strings.
                object[name] = (seen.contains(name) ? object[name] as? [Any] ?? [] : []) + [raw]
                seen.insert(name); index += 2
                continue
            }
            guard seen.insert(name).inserted else { throw ToolProviderError("\(flag) was given more than once.") }
            switch type {
            case "integer":
                guard let value = Int(raw) else { throw ToolProviderError("\(flag) needs a whole number.") }
                object[name] = value
            case "number":
                guard let value = Double(raw), value.isFinite else { throw ToolProviderError("\(flag) needs a number.") }
                object[name] = value
            case "array": object[name] = json
            case "object":
                guard let value = json as? [String: Any] else { throw ToolProviderError("\(flag) needs a JSON object.") }
                object[name] = value
            default: object[name] = raw
            }
            index += 2
        }
        // Flags win over the seed wherever --input appears.
        return try JSONSerialization.data(withJSONObject: (seed ?? [:]).merging(object) { $1 }, options: [.sortedKeys])
    }

    /// Exact names win; `--max-results` also reaches `max_results` or `maxResults`.
    private static func property(_ flag: String, in properties: [String: Any]) -> String? {
        if properties[flag] != nil { return flag }
        let fold: (String) -> String = { $0.lowercased().filter { $0 != "-" && $0 != "_" } }
        let matches = properties.keys.filter { fold($0) == fold(flag) }
        return matches.count == 1 ? matches[0] : nil
    }
}
