import CryptoKit
import Foundation
import HubCore
import HubLink
import NoodleCore
import NoodleMCP
import NoodleRuntime
import Observation

/// This Mac serving its owner's devices, while they have it switched on in Settings > Hub: a
/// phone or another Mac joined to it talks to the bots here as it would a Noodle Hub's. The Mac
/// stays awake meanwhile, since a sleeping Mac answers nobody.
@MainActor @Observable final class ThisMacHub {
    private(set) var hub: PersonalHub?
    var isOn: Bool { hub != nil }
    /// Its key, once it has served its owner's devices, who name this Mac's bots and groups by it; so do spaces.
    var key: String? = ThisMacHub.savedKey()
    /// Runs after a device made, changed or deleted a bot, so Noodle reloads its bots.
    @ObservationIgnored var onBotsEdited: (() -> Void)?
    /// Runs after a device changed tools, computers or browsers, so Noodle reads them again.
    @ObservationIgnored var onToolsEdited: (() -> Void)?
    /// Runs when the owner read a conversation further on one of their devices.
    @ObservationIgnored var onRead: ((_ conversationID: UUID, _ upTo: Date) -> Void)?
    /// Runs when a device changed a conversation's background.
    @ObservationIgnored var onBackgroundChanged: ((_ conversationID: UUID) -> Void)?
    /// Runs when the owner pinned or unpinned on one of their devices.
    @ObservationIgnored var onPinsEdited: (() -> Void)?

    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let runtime: AgentRuntimeCoordinator
    @ObservationIgnored private let applets: AppletController
    @ObservationIgnored private let profiles: HarnessProfilesController
    @ObservationIgnored private let service: MCPService
    @ObservationIgnored private var awake: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    private static let enabledKey = "ThisMacHubEnabled"

    init(repository: WorkspaceRepository, runtime: AgentRuntimeCoordinator, applets: AppletController,
         profiles: HarnessProfilesController, service: MCPService, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.runtime = runtime
        self.applets = applets
        self.profiles = profiles
        self.service = service
        self.defaults = defaults
    }

    /// At launch: on again if it was on.
    func restore() async {
        if defaults.bool(forKey: Self.enabledKey) { await setOn(true) }
    }

    func setOn(_ on: Bool) async {
        defaults.set(on, forKey: Self.enabledKey)
        if on, hub == nil {
            let directory = Self.directory
            let port = (Bundle.main.object(forInfoDictionaryKey: "NoodlePersonalHubPort") as? String).flatMap(UInt16.init)
            let hub = PersonalHub(name: Host.current().localizedName ?? "My Mac", directory: directory, repository: repository,
                                  runtime: runtime, applets: applets, profiles: profiles, service: service, port: port ?? PersonalHub.port,
                                  // As a Noodle Hub does: the router forwards the port, for devices away from home.
                                  router: SystemRouterPortMapper())
            // Copies of bots kept on joined Hubs are those Hubs', not this Mac's.
            hub.bots.isHidden = { [runtime] in runtime.remoteAgentIDs.contains($0) }
            hub.bots.onBotsEdited = { [weak self] in self?.onBotsEdited?() }
            hub.onRead = { [weak self] in self?.onRead?($0, $1) }
            hub.bots.onBackgroundChanged = { [weak self] in self?.onBackgroundChanged?($0) }
            hub.onToolsEdited = { [weak self] in self?.onToolsEdited?() }
            hub.onPinsEdited = { [weak self] in self?.onPinsEdited?() }
            self.hub = hub
            key = hub.link.key.x963.base64EncodedString()
            await hub.start()
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                          reason: "Your devices can reach this Mac")
        } else if !on, let hub {
            hub.stop()
            self.hub = nil
            if let awake { ProcessInfo.processInfo.endActivity(awake) }
            awake = nil
        }
    }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("This Mac Hub", isDirectory: true)
    }

    /// The key it was served with before, without making one.
    private static func savedKey() -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("Link/hub.key")),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else { return nil }
        return LinkPublicKey(key.publicKey).x963.base64EncodedString()
    }
}
