import ExtensionFoundation
import Foundation
import NoodleCore
import Observation

/// Noodle's extension point. The app's build extracts this definition into
/// `Contents/Extensions/Noodle.appexpt`; the identifier is `<bundle identifier>.tool`.
extension AppExtensionPoint {
    @Definition static var noodleTool: AppExtensionPoint {
        Name("tool")
        UserInterface(false)
    }
}

/// Keeps the provider registry in step with installed tool extensions. Adding tools
/// to Noodle means bundling an extension; nothing here names one.
@MainActor final class ToolExtensionDiscovery {
    private let registry: ToolProviderRegistry
    private var monitor: AppExtensionPoint.Monitor?
    private var providers: [AppExtensionIdentity: String] = [:]
    private var pending: Set<AppExtensionIdentity> = []

    init(registry: ToolProviderRegistry) { self.registry = registry }

    func start() {
        guard monitor == nil else { return }
        Task {
            do {
                monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .noodleTool)
                observe()
            } catch { NSLog("Noodle tool extensions are unavailable: %@", String(describing: error)) }
        }
    }

    private func observe() {
        guard let monitor else { return }
        let identities = withObservationTracking { monitor.identities } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        for (identity, id) in providers where !identities.contains(identity) {
            registry.unregister(id)
            providers[identity] = nil
        }
        for identity in identities where providers[identity] == nil && pending.insert(identity).inserted {
            Task {
                defer { pending.remove(identity) }
                do {
                    let process = ExtensionProcess(identity: identity)
                    let provider = try await ToolExtensionConnection(kind: .appExtension) { try await process.connect() }
                    try registry.register(provider)
                    providers[identity] = provider.manifest.id
                } catch {
                    NSLog("Noodle could not load the %@ tool extension: %@", identity.bundleIdentifier, error.localizedDescription)
                }
            }
        }
    }

    /// The system stops idle extensions, so each reconnection starts a fresh process.
    private actor ExtensionProcess {
        private let identity: AppExtensionIdentity
        private var process: AppExtensionProcess?
        init(identity: AppExtensionIdentity) { self.identity = identity }
        func connect() async throws -> NSXPCConnection {
            process?.invalidate()
            let started = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity))
            process = started
            return try started.makeXPCConnection()
        }
    }
}
