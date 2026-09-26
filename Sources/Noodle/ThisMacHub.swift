import Foundation
import HubCore
import NoodleCore
import NoodleRuntime
import Observation

/// This Mac serving its owner's devices, while they have it switched on in Settings > Hub: a
/// phone or another Mac joined to it talks to the bots here as it would a Noodle Hub's. The Mac
/// stays awake meanwhile, since a sleeping Mac answers nobody.
@MainActor @Observable final class ThisMacHub {
    private(set) var hub: PersonalHub?
    var isOn: Bool { hub != nil }
    /// Runs after a device made, changed or deleted a bot, so Noodle reloads its bots.
    @ObservationIgnored var onBotsEdited: (() -> Void)?

    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let runtime: AgentRuntimeCoordinator
    @ObservationIgnored private let applets: AppletController
    @ObservationIgnored private let profiles: HarnessProfilesController
    @ObservationIgnored private var awake: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    private static let enabledKey = "ThisMacHubEnabled"

    init(repository: WorkspaceRepository, runtime: AgentRuntimeCoordinator, applets: AppletController,
         profiles: HarnessProfilesController, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.runtime = runtime
        self.applets = applets
        self.profiles = profiles
        self.defaults = defaults
    }

    /// At launch: on again if it was on.
    func restore() async {
        if defaults.bool(forKey: Self.enabledKey) { await setOn(true) }
    }

    func setOn(_ on: Bool) async {
        defaults.set(on, forKey: Self.enabledKey)
        if on, hub == nil {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("This Mac Hub", isDirectory: true)
            let port = (Bundle.main.object(forInfoDictionaryKey: "NoodlePersonalHubPort") as? String).flatMap(UInt16.init)
            let hub = PersonalHub(name: Host.current().localizedName ?? "My Mac", directory: directory, repository: repository,
                                  runtime: runtime, applets: applets, profiles: profiles, port: port ?? PersonalHub.port,
                                  // As a Noodle Hub does: the router forwards the port, for devices away from home.
                                  router: SystemRouterPortMapper())
            // Copies of bots kept on joined Hubs are those Hubs', not this Mac's.
            hub.bots.isHidden = { [runtime] in runtime.remoteAgentIDs.contains($0) }
            hub.bots.onBotsEdited = { [weak self] in self?.onBotsEdited?() }
            self.hub = hub
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
}
