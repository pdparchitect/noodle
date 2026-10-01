import Foundation
import HubLink

/// How devices away from home can reach a Hub, from what its Mac knows. Nothing here is tried
/// from outside: an open port can still be blocked further along, and an address the owner
/// typed in is taken on trust.
public struct HubReachability: Equatable, Sendable {
    public enum Route: Equatable, Sendable { case tailscale, internet, address }

    public let routes: [Route]
    /// The owner asked the router to open the port, it did not, and nothing else reaches the Hub.
    public let isWarning: Bool

    public init(endpoints: [LinkEndpoint], router: HubLinkService.RouterState, manual: LinkEndpoint?) {
        let others = endpoints.filter { $0 != manual }
        var routes: [Route] = []
        if endpoints.contains(where: { $0.network == .tailnet }) { routes.append(.tailscale) }
        if others.contains(where: { $0.network == .internet }) { routes.append(.internet) }
        if let manual, manual.network != .tailnet { routes.append(.address) }
        self.routes = routes
        if case .failed = router { isWarning = routes.isEmpty } else { isWarning = false }
    }

    public var summary: String {
        guard !routes.isEmpty else { return "Reachable only on this network" }
        let names = routes.map { route in
            switch route {
            case .tailscale: "Tailscale"
            case .internet: "the internet"
            case .address: "your address"
            }
        }
        return "Reachable from anywhere through \(names.formatted(.list(type: .and)))"
    }
}

extension HubLinkService {
    public var reachability: HubReachability { HubReachability(endpoints: endpoints, router: router, manual: manualEndpoint) }
}
