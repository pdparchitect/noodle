import ComputerBridge
import Foundation
import HubLink
import NoodleComputerTools
import NoodleCore
import NoodleMCP
import NoodleRuntime

/// The Hub's bots, harnesses and conversations. They live in the Hub's own sandbox
/// container, apart from Noodle's; the folder name is the one the Agent Host looks in.
@MainActor public final class Hub {
    public static let folderName = "Noodle"

    public let repository: WorkspaceRepository
    public let runtime: AgentRuntimeCoordinator
    public let harnessProfiles: HarnessProfilesController
    public let usage: UsageHistory
    public let access: HubAccess
    public let connections: HubConnections
    public let computers: HubComputers
    public let bots: HubBots
    public let link: HubLinkService

    /// `computer` reaches Noodle Computer on this Mac; tests pass their own.
    public init(root: URL, messenger: URL?, linkPort: UInt16 = LinkEndpoint.defaultPort, router: (any RouterPortMapper)? = nil,
                computer: ComputerToolProvider.Transport? = nil) {
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: messenger)
        // Only the Hub's own storage holds harnesses its Agent Host will trust.
        let discovery = HarnessDiscovery(managedHarnesses: repository.managedHarnesses)
        discovery.removeSupersededManagedHarnesses()
        runtime = AgentRuntimeCoordinator(discovery: discovery)
        harnessProfiles = HarnessProfilesController(store: repository.harnessProfiles)
        usage = UsageHistory(url: root.appendingPathComponent("usage.sqlite"))
        runtime.onUsage = { [usage] in usage.record($0) }
        access = HubAccess(url: root.appendingPathComponent("access.json"))
        // One broker serves every tool a bot is given here, whichever kind it is.
        let tools = ToolProviderRegistry(), assignments = ToolAssignmentStore()
        connections = HubConnections(root: root, access: access,
                                     service: MCPService(namespace: Bundle.main.bundleIdentifier ?? "com.pdparchitect.noodle.hub"),
                                     tools: tools, assignments: assignments)
        computers = HubComputers(root: root, access: access, tools: tools, assignments: assignments,
                                 call: computer ?? ComputerToolProvider.liveTransport())
        bots = HubBots(repository: repository, runtime: runtime, access: access, connections: connections, computers: computers,
                       uploads: root.appendingPathComponent("Uploads", isDirectory: true))
        link = HubLinkService(hubName: Host.current().localizedName ?? "Noodle Hub",
                              directory: root.appendingPathComponent("Link", isDirectory: true),
                              access: access, profiles: harnessProfiles, bots: bots, connections: connections, port: linkPort, router: router)
    }

    /// Removes a user with their devices and the bots they keep here.
    public func remove(_ user: HubUser) {
        bots.removeBots(of: user)
        connections.removeConnections(of: user)
        computers.removeComputers(of: user)
        access.remove(user)
    }

    public static func root(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(folderName, isDirectory: true)
    }
}
