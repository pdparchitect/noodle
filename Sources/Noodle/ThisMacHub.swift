import CryptoKit
import Foundation
import HubCore
import HubLink
import HubMac
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
    /// Noodle's image models and grants, which the owner's devices change for its bots.
    @ObservationIgnored var imageGeneration: ImageGenerationController?
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
    /// Runs when the owner muted or unmuted a group on one of their devices.
    @ObservationIgnored var onNotificationsEdited: (() -> Void)?
    /// A bot here's sharing on the Hubs this Mac joined, and sharing it on one, for the owner's phone.
    @ObservationIgnored var hubSharing: ((UUID) async throws -> [LinkHubSharing])?
    @ObservationIgnored var shareOnHub: ((UUID, String, [UUID]) async throws -> [LinkHubSharing])?
    /// Runs when a call from a bot here stopped ringing on the owner's devices: answered or declined on
    /// one, or not answered in time.
    @ObservationIgnored var onCallStopped: ((_ id: UUID) -> Void)?

    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let runtime: AgentRuntimeCoordinator
    @ObservationIgnored private let applets: AppletController
    @ObservationIgnored private let profiles: HarnessProfilesController
    @ObservationIgnored private let service: MCPService
    @ObservationIgnored private var awake: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    private static let enabledKey = "ThisMacHubEnabled"

    /// Where it keeps its key and devices, and where devices reach it.
    struct Placement {
        var directory = ThisMacHub.directory
        /// The port this build listens on; nil for its usual one.
        var port: UInt16? = (Bundle.main.object(forInfoDictionaryKey: "NoodlePersonalHubPort") as? String).flatMap(UInt16.init)
        /// As a Noodle Hub does: the router forwards the port, for devices away from home.
        var router: (any RouterPortMapper)? = SystemRouterPortMapper()
        var localEndpoints: (UInt16) -> [LinkEndpoint] = LinkEndpoint.local(port:)
    }
    /// The Mac's own, unless a test gives another before switching it on.
    @ObservationIgnored var placement = Placement()

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

    /// The person's choice; never on while the organisation forbids it.
    func setOn(_ on: Bool) async {
        guard !on || Organisation.allows(.hubHosting) else { return }
        defaults.set(on, forKey: Self.enabledKey)
        await serve(on)
    }

    /// Stops while the organisation forbids it and comes back after if the person had it on, keeping their choice.
    func applyOrganisationPolicy() async {
        await serve(Organisation.allows(.hubHosting) && defaults.bool(forKey: Self.enabledKey))
    }

    private func serve(_ on: Bool) async {
        if on, hub == nil {
            let hub = PersonalHub(name: Host.current().localizedName ?? "My Mac", directory: placement.directory, repository: repository,
                                  runtime: runtime, applets: applets, profiles: profiles, service: service,
                                  port: placement.port ?? PersonalHub.port, router: placement.router,
                                  localEndpoints: placement.localEndpoints)
            // Copies of bots kept on joined Hubs are those Hubs', not this Mac's.
            hub.bots.isHidden = { [runtime] in runtime.remoteAgentIDs.contains($0) }
            hub.bots.onBotsEdited = { [weak self] in self?.onBotsEdited?() }
            hub.imageGeneration = imageGeneration
            hub.onRead = { [weak self] in self?.onRead?($0, $1) }
            hub.bots.onBackgroundChanged = { [weak self] in self?.onBackgroundChanged?($0) }
            hub.onToolsEdited = { [weak self] in self?.onToolsEdited?() }
            hub.onPinsEdited = { [weak self] in self?.onPinsEdited?() }
            hub.onNotificationsEdited = { [weak self] in self?.onNotificationsEdited?() }
            hub.link.hubSharing = { [weak self] in try await self?.hubSharing?($0) ?? [] }
            hub.link.shareOnHub = { [weak self] in
                guard let share = self?.shareOnHub else { throw LinkError("Noodle is closing.") }
                return try await share($0, $1, $2)
            }
            hub.bots.onCallStopped = { [weak self] in self?.onCallStopped?($0) }
            self.hub = hub
            key = hub.link.key.x963.base64EncodedString()
            await hub.start()
            // A call already ringing here rings on the owner's devices too.
            hub.bots.ringPendingCalls()
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                          reason: "Your devices can reach this Mac")
        } else if !on, let hub {
            hub.stop()
            self.hub = nil
            if let awake { ProcessInfo.processInfo.endActivity(awake) }
            awake = nil
        }
    }

    /// Rings a call a bot here placed on the owner's devices too, while it serves them. Whichever rings
    /// it, here or there, the bot's pending call ends once, so its conversation gets one card at most.
    func ringCall(of agentID: UUID, now: Date = Date()) { hub?.bots.ringCall(of: agentID, now: now) }

    /// Stops a call ringing on the owner's devices once this Mac answered, declined or missed it.
    func stopRinging(_ id: UUID) { hub?.bots.stopRinging(id) }

    nonisolated private static var directory: URL {
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
