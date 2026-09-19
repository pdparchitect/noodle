import Foundation

/// NSXPC contract between Noodle and a tool extension. Payloads are the same JSON
/// as `ToolProvider`; files cross the sandbox boundary as handles, never as paths.
@objc public protocol ToolExtensionXPC {
    func manifest(reply: @escaping (Data) -> Void)
    func listTools(agent: String, reply: @escaping (Data?, String?) -> Void)
    /// `files[i]` belongs to `parameters[i]`; `writable[i]` tells how it was opened.
    func callTool(_ name: String, arguments: Data, files: [FileHandle], parameters: [String], writable: [Bool],
                  agent: String, reply: @escaping (Data?, String?) -> Void)
}

public enum ToolExtensionInterface {
    /// Collections of handles must be allow-listed for NSXPC secure coding on both ends.
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: ToolExtensionXPC.self)
        let selector = #selector(ToolExtensionXPC.callTool(_:arguments:files:parameters:writable:agent:reply:))
        interface.setClasses(NSSet(array: [NSArray.self, FileHandle.self]) as! Set<AnyHashable>, for: selector, argumentIndex: 2, ofReply: false)
        interface.setClasses(NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>, for: selector, argumentIndex: 3, ofReply: false)
        interface.setClasses(NSSet(array: [NSArray.self, NSNumber.self]) as! Set<AnyHashable>, for: selector, argumentIndex: 4, ofReply: false)
        return interface
    }
}

/// Extension side: exports any `ToolProvider`. An extension is a provider plus
/// `ToolExtensionService(provider:).accept(connection)`.
public final class ToolExtensionService: NSObject, ToolExtensionXPC, @unchecked Sendable {
    private let provider: any ToolProvider
    public init(provider: any ToolProvider) { self.provider = provider }

    public func accept(_ connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = ToolExtensionInterface.make()
        connection.exportedObject = self
        connection.resume()
        return true
    }

    public func manifest(reply: @escaping (Data) -> Void) { reply((try? JSONEncoder().encode(provider.manifest)) ?? Data()) }

    public func listTools(agent: String, reply: @escaping (Data?, String?) -> Void) {
        respond(reply) { try await self.provider.tools(context: Self.context(agent)) }
    }

    public func callTool(_ name: String, arguments: Data, files: [FileHandle], parameters: [String], writable: [Bool],
                         agent: String, reply: @escaping (Data?, String?) -> Void) {
        respond(reply) {
            guard files.count == parameters.count, files.count == writable.count else { throw ToolProviderError("Mismatched tool files.") }
            let opened = files.indices.map { ToolFile(parameter: parameters[$0], access: writable[$0] ? .write : .read, handle: files[$0]) }
            return try await self.provider.call(name, arguments: arguments, files: opened, context: Self.context(agent))
        }
    }

    /// An extension is sandboxed away from the workspace; it learns only who is calling.
    private static func context(_ agent: String) -> ToolCallContext {
        ToolCallContext(agentID: UUID(uuidString: agent) ?? UUID(), workspace: URL(fileURLWithPath: "/"))
    }

    private func respond(_ reply: @escaping (Data?, String?) -> Void, _ work: @escaping @Sendable () async throws -> Data) {
        let reply = UncheckedReply(reply)
        Task {
            do { reply.send(try await work(), nil) } catch { reply.send(nil, error.localizedDescription) }
        }
    }
    private struct UncheckedReply: @unchecked Sendable {
        let send: (Data?, String?) -> Void
        init(_ send: @escaping (Data?, String?) -> Void) { self.send = send }
    }
}

/// App side: a provider backed by an extension process. `connect` makes a fresh
/// connection, so an extension the system stopped while idle starts again on the next call.
public final class ToolExtensionConnection: ToolProvider, @unchecked Sendable {
    public let kind: ToolProviderKind
    public let manifest: ToolProviderManifest
    private let connect: @Sendable () async throws -> NSXPCConnection
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    /// An extension that starts but never answers must fail discovery, not stall it.
    public init(kind: ToolProviderKind, manifestTimeout: TimeInterval = 15,
                connect: @escaping @Sendable () async throws -> NSXPCConnection) async throws {
        self.kind = kind; self.connect = connect
        let connection = try await Self.open(connect)
        let manifest: ToolProviderManifest
        do {
            let pending = UncheckedConnection(connection)
            let data = try await ToolBroker.withTimeout(manifestTimeout, tool: "The tool extension") {
                try await Self.request(pending.value) { proxy, finish in proxy.manifest { finish($0, nil) } }
            }
            manifest = try JSONDecoder().decode(ToolProviderManifest.self, from: data)
            try manifest.validate()
        } catch { connection.invalidate(); throw error }
        self.manifest = manifest
        self.connection = connection
        watch(connection)
    }
    deinit { connection?.invalidate() }

    public func tools(context: ToolCallContext) async throws -> Data {
        try await perform { proxy, finish in proxy.listTools(agent: context.agentID.uuidString, reply: finish) }
    }

    public func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
        try await perform { proxy, finish in
            proxy.callTool(tool, arguments: arguments, files: files.map(\.handle), parameters: files.map(\.parameter),
                           writable: files.map { $0.access == .write }, agent: context.agentID.uuidString, reply: finish)
        }
    }

    private func perform(_ body: @escaping (ToolExtensionXPC, @escaping (Data?, String?) -> Void) -> Void) async throws -> Data {
        if let connection = lock.withLock({ connection }) { return try await Self.request(connection, body) }
        let fresh = try await Self.open(connect)
        // Two calls may reconnect at once; keep the first and drop the other.
        let chosen = lock.withLock { () -> NSXPCConnection in
            if let connection { return connection }
            connection = fresh
            return fresh
        }
        if chosen === fresh { watch(fresh) } else { fresh.invalidate() }
        return try await Self.request(chosen, body)
    }

    /// The system stops idle extensions. Forget the connection so the next call starts it again.
    private func watch(_ connection: NSXPCConnection) {
        let watched = WeakConnection(connection)
        let forget: @Sendable () -> Void = { [weak self] in
            self?.lock.withLock { if self?.connection === watched.value { self?.connection = nil } }
        }
        connection.invalidationHandler = forget
        connection.interruptionHandler = { forget(); watched.value?.invalidate() }
    }
    private struct UncheckedConnection: @unchecked Sendable {
        let value: NSXPCConnection
        init(_ value: NSXPCConnection) { self.value = value }
    }
    private final class WeakConnection: @unchecked Sendable {
        weak var value: NSXPCConnection?
        init(_ value: NSXPCConnection) { self.value = value }
    }

    private static func open(_ connect: () async throws -> NSXPCConnection) async throws -> NSXPCConnection {
        let connection = try await connect()
        connection.remoteObjectInterface = ToolExtensionInterface.make()
        connection.resume()
        return connection
    }

    private static func request(_ connection: NSXPCConnection,
                                _ body: @escaping (ToolExtensionXPC, @escaping (Data?, String?) -> Void) -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // NSXPC calls exactly one of the error handler or the reply.
            let proxy = connection.remoteObjectProxyWithErrorHandler {
                continuation.resume(throwing: ToolProviderError("The tool extension stopped: \($0.localizedDescription)"))
            }
            guard let remote = proxy as? ToolExtensionXPC else {
                return continuation.resume(throwing: ToolProviderError("The extension does not provide Noodle tools."))
            }
            body(remote) { data, error in
                if let data, error == nil { continuation.resume(returning: data) }
                else { continuation.resume(throwing: ToolProviderError(error ?? "The tool extension returned nothing.")) }
            }
        }
    }
}
