import Foundation
import NoodleCore

/// Keeps one tool provider registered per saved connection. Each call reads the connection
/// as it is at that moment, since its endpoint or account may have been edited since.
@MainActor public final class MCPConnectionProviders {
    private let registry: ToolProviderRegistry
    private let service: MCPService
    private var signatures: [UUID: String] = [:]
    /// Called with a failure already safe to show, for the connection it happened on.
    public var onError: ((UUID, String) -> Void)?

    public init(registry: ToolProviderRegistry, service: MCPService) {
        self.registry = registry
        self.service = service
    }

    /// Registers what `connections` adds or changes and unregisters what it no longer has.
    /// `current` looks a connection up at call time; nil means it was removed.
    public func synchronize(_ connections: [MCPConnectionRecord],
                            current: @escaping @MainActor (UUID) -> MCPConnectionRecord?) {
        let wanted = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0.skillName + "\n" + $0.name + "\n" + $0.description + "\n" + $0.instructions) })
        for (id, signature) in signatures where wanted[id] != signature {
            registry.unregister(String(signature.prefix { $0 != "\n" }))
            signatures[id] = nil
        }
        for connection in connections where signatures[connection.id] == nil {
            let id = connection.id, service = service
            let provider = ConnectionToolProvider(id: connection.skillName, title: connection.name, connection: id,
                summary: connection.description, userInstructions: connection.instructions) { [weak self] action, tool, arguments, uri, authorized in
                guard let current = await current(id) else { throw MCPServiceError.revoked }
                do {
                    return try await service.perform(MCPBridgeRequest(session: "", connectionID: id, action: action, tool: tool, arguments: arguments, uri: uri),
                                                     connection: current, authorized: authorized)
                } catch {
                    let message = Self.safeError(error)
                    await self?.onError?(id, message)
                    throw ToolProviderError(message)
                }
            }
            do { try registry.register(provider); signatures[id] = wanted[id] }
            catch { onError?(id, error.localizedDescription) }
        }
    }

    /// Only Noodle's own errors are shown; anything else may carry a provider's private response.
    public nonisolated static func safeError(_ error: Error) -> String {
        if error is MCPServiceError || error is MCPConnectionError { return error.localizedDescription }
        return "The tool connection could not complete the request. Try reconnecting in Settings → Tools."
    }
}
