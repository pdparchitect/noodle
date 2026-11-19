import Foundation
import NoodleCore

/// Keeps one tool provider registered per saved connection. Each call reads the connection
/// as it is at that moment, since its endpoint or account may have been edited since.
@MainActor public final class ToolConnectionProviders {
    private let registry: ToolProviderRegistry
    private let service: ToolConnectionService
    private var signatures: [UUID: String] = [:]
    /// Called on the main actor with a failure already safe to show, for the connection it
    /// happened on. Calls fail on background tasks, and whoever shows the error keeps it there.
    public var onError: (@MainActor (UUID, String) -> Void)?
    /// What the app says about a connection in its skill, before the person's own instructions, if anything.
    public var appInstructions: (@MainActor (ToolConnection) -> String?)?

    public init(registry: ToolProviderRegistry, service: ToolConnectionService) {
        self.registry = registry
        self.service = service
    }

    /// Registers what `connections` adds or changes and unregisters what it no longer has.
    /// `current` looks a connection up at call time; nil means it was removed.
    public func synchronize(_ connections: [ToolConnection],
                            current: @escaping @MainActor (UUID) -> ToolConnection?) {
        let said = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, appInstructions?($0) ?? "") })
        let wanted = Dictionary(uniqueKeysWithValues: connections.map {
            ($0.id, $0.skillName + "\n" + $0.name + "\n" + $0.description + "\n" + $0.instructions + "\n" + said[$0.id, default: ""])
        })
        for (id, signature) in signatures where wanted[id] != signature {
            registry.unregister(String(signature.prefix { $0 != "\n" }))
            signatures[id] = nil
        }
        for connection in connections where signatures[connection.id] == nil {
            let id = connection.id, service = service
            let provider = ConnectionToolProvider(id: connection.skillName, title: connection.name, connection: id,
                summary: connection.description, appInstructions: said[id, default: ""],
                userInstructions: connection.instructions) { [weak self] action, tool, arguments, uri, authorized in
                guard let current = await current(id) else { throw ToolConnectionServiceError.revoked }
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
        if error is ToolConnectionServiceError || error is ToolConnectionError { return error.localizedDescription }
        // The system's own words for a network failure, such as a refused connection or an untrusted certificate,
        // carry nothing from the service, and say what to fix.
        if let failure = error as? URLError {
            return "The service could not be reached: \(failure.localizedDescription) (\(failure.code.rawValue))"
        }
        // Only the kind of error, never its text, which may carry what the service said.
        let kind = error as NSError
        return "The tool connection could not complete the request (\(kind.domain) \(kind.code)). Try reconnecting in Settings → Tools."
    }
}
