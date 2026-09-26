import Foundation
import HubLink
import NoodleComputerTools
import NoodleBrowserTools
import NoodleCore
import NoodleMCP
import NoodleRuntime

/// Noodle serving its own owner's devices, as a Noodle Hub serves the people it lends to: a phone
/// or another Mac joined to it sees the bots already on this Mac and talks to them. Nobody else
/// can be added, and the bots keep running in Noodle; this only tells devices what changes and
/// takes what they send.
@MainActor public final class PersonalHub {
    /// Beside a Noodle Hub's, and its development build's, so all can serve from one Mac. A
    /// development Noodle names its own in its Info.plist.
    public static let port = LinkEndpoint.defaultPort + 2

    public let access: HubAccess
    public let bots: HubBots
    public let link: HubLinkService
    private let connections: HubConnections
    private let computers: HubComputers
    private let browsers: HubBrowsers

    /// The only user: this Mac's owner, on every device they join.
    public var owner: HubUser { access.users[0] }

    public init(name: String, directory: URL, repository: WorkspaceRepository, runtime: AgentRuntimeCoordinator,
                applets: AppletController, profiles: HarnessProfilesController, port: UInt16 = PersonalHub.port,
                router: (any RouterPortMapper)? = nil,
                localEndpoints: @escaping (UInt16) -> [LinkEndpoint] = LinkEndpoint.local(port:)) {
        access = HubAccess(url: directory.appendingPathComponent("access.json"), personal: true)
        // Noodle keeps its own tools, computers and browsers for its bots; these only answer devices.
        let tools = ToolProviderRegistry(), assignments = ToolAssignmentStore()
        connections = HubConnections(root: directory, access: access,
                                     service: MCPService(namespace: (Bundle.main.bundleIdentifier ?? "com.pdparchitect.noodle") + ".personal-hub"),
                                     tools: tools, assignments: assignments)
        computers = HubComputers(root: directory, access: access, tools: tools, assignments: assignments,
                                 call: ComputerToolProvider.liveTransport())
        browsers = HubBrowsers(root: directory, access: access, tools: tools, assignments: assignments,
                               call: BrowserToolProvider.liveTransport())
        bots = HubBots(repository: repository, runtime: runtime, access: access, connections: connections, computers: computers,
                       browsers: browsers, applets: applets, uploads: directory.appendingPathComponent("Uploads", isDirectory: true))
        link = HubLinkService(hubName: name, directory: directory.appendingPathComponent("Link", isDirectory: true),
                              access: access, profiles: profiles, bots: bots, connections: connections, computers: computers,
                              browsers: browsers, port: port, router: router, localEndpoints: localEndpoints)
    }

    public func start() async {
        bots.watch()
        await link.start()
    }

    public func stop() {
        link.stop()
        bots.stopWatching()
    }
}
