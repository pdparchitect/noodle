import AppletBridge
import Foundation
import HubCore
import HubLink
import Network
import NoodleRuntime

extension HubLinkService {
    /// A Hub on a Mac: devices reach it over QUIC, it follows the Mac's network, and offers this Mac's addresses.
    public convenience init(hubName: String, directory: URL, access: HubAccess, profiles: HarnessProfilesController,
                            bots: HubBots? = nil, connections: HubConnections? = nil, computers: (any HubComputing)? = nil,
                            browsers: (any HubBrowsing)? = nil,
                            port: UInt16 = LinkEndpoint.defaultPort, router: (any RouterPortMapper)? = nil,
                            routerChecks: RouterChecks = .standard,
                            localEndpoints: @escaping (UInt16) -> [LinkEndpoint] = LinkEndpoint.local(port:),
                            now: @escaping () -> Date = Date.init, pushes: (any HubPushPublisher)? = nil, pushDelay: Duration = .seconds(2),
                            callPushes: (any CallPushTransport)? = nil, callPushLog: ((String) -> Void)? = nil) {
        self.init(hubName: hubName, directory: directory, access: access, profiles: profiles, bots: bots, connections: connections,
                  computers: computers, browsers: browsers, port: port, listen: LinkServer.listen, network: PathNetworkWatcher(),
                  router: router, routerChecks: routerChecks, localEndpoints: localEndpoints, now: now, pushes: pushes,
                  pushDelay: pushDelay, callPushes: callPushes, callPushLog: callPushLog)
    }
}

/// Follows the Mac's network: its interface and routers.
@MainActor final class PathNetworkWatcher: HubNetworkWatching {
    private var monitor: NWPathMonitor?

    func start(_ changed: @escaping @MainActor (String) -> Void) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let network = "\(path.status) \(path.availableInterfaces.first?.name ?? "") \(path.gateways)"
            Task { @MainActor in changed(network) }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

/// A live view Noodle Computer, Browser or Applet streams to this Mac, relayed as it comes.
struct SurfaceLiveView: HubLiveView {
    let socket: SurfaceSocket

    func relay(to stream: any LinkServerStream) { LinkSurface.relay(socket, to: stream) }
}

extension AppletController: HubNoodletRunning {
    public func liveView(_ request: AppletRequest) async throws -> any HubLiveView {
        SurfaceLiveView(socket: try await companionSurface(request))
    }
}
