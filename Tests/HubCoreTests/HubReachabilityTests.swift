@testable import HubCore
import HubLink
import XCTest

/// How devices away from home can reach a Hub, from what its Mac knows.
final class HubReachabilityTests: XCTestCase {
    private let home = [LinkEndpoint(host: "Mac.local", port: 38_415), LinkEndpoint(host: "192.168.1.203", port: 38_415),
                        LinkEndpoint(host: "fddf:963a:f004::1", port: 38_415)]
    private let tailnet = [LinkEndpoint(host: "mac.tail325532.ts.net", port: 38_415), LinkEndpoint(host: "100.90.231.122", port: 38_415)]
    private let opened = RouterMapping(endpoint: LinkEndpoint(host: "88.97.106.9", port: 38_415), method: .upnp, lifetime: 0)

    func testOnlyHomeAddressesReachOnlyThisNetwork() {
        let reachability = HubReachability(endpoints: home, router: .off, manual: nil)
        XCTAssertEqual(reachability.routes, [])
        XCTAssertFalse(reachability.isWarning)
    }

    func testEveryRouteInIsNamed() {
        let manual = LinkEndpoint(host: "hub.example.com", port: 38_415)
        let reachability = HubReachability(endpoints: home + tailnet + [opened.endpoint, manual], router: .open(opened), manual: manual)
        XCTAssertEqual(reachability.routes, [.tailscale, .internet, .address])
    }

    func testARouterThatRefusedIsAWarningOnlyWithNoOtherWayIn() {
        let refused = HubLinkService.RouterState.failed("The router did not answer.")
        XCTAssertTrue(HubReachability(endpoints: home, router: refused, manual: nil).isWarning)
        let throughTailscale = HubReachability(endpoints: home + tailnet, router: refused, manual: nil)
        XCTAssertEqual(throughTailscale.routes, [.tailscale])
        XCTAssertFalse(throughTailscale.isWarning)
    }

    func testAPublicAddressOnTheMacItselfReachesTheInternet() {
        let reachability = HubReachability(endpoints: home + [LinkEndpoint(host: "203.0.113.9", port: 38_415)], router: .off, manual: nil)
        XCTAssertEqual(reachability.routes, [.internet])
    }
}
