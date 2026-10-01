@testable import HubLink
import XCTest

/// What a device that cannot reach its Hub suggests, from what it found out about itself.
final class HubTroubleshootingTests: XCTestCase {
    private let home = [LinkEndpoint(host: "Mac-mini.local", port: 38_415), LinkEndpoint(host: "192.168.1.20", port: 38_415)]
    private let tailnet = [LinkEndpoint(host: "mac-mini.tail1234.ts.net", port: 38_415), LinkEndpoint(host: "100.101.1.2", port: 38_415)]
    private let wifi = HubTroubleshooting.Device(isOnline: true, isOnWiFi: true, isOnTailnet: false, isLocalNetworkDenied: false)

    func testAddressesAreSortedByHowTheyAreReached() {
        let homes = ["Mac-mini.local", "10.0.0.4", "172.20.1.1", "192.168.1.20", "fe80::1", "2a01:4b00::1"]
        for host in homes { XCTAssertEqual(LinkEndpoint(host: host, port: 38_415).network, .home, host) }
        let tailnets = ["mac-mini.tail1234.ts.net", "100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1"]
        for host in tailnets { XCTAssertEqual(LinkEndpoint(host: host, port: 38_415).network, .tailnet, host) }
        for host in ["203.0.113.9", "100.128.0.1", "172.32.0.1", "hub.example.com"] {
            XCTAssertEqual(LinkEndpoint(host: host, port: 38_415).network, .internet, host)
        }
    }

    func testOfflineIsAllThatIsSaid() {
        var device = wifi
        device.isOnline = false
        device.isLocalNetworkDenied = true
        XCTAssertEqual(HubTroubleshooting.advice(for: home + tailnet, on: device), [.goOnline])
    }

    func testAHomeHubOnWiFiAsksForTheSameWiFiThenTheMac() {
        XCTAssertEqual(HubTroubleshooting.advice(for: home, on: wifi), [.joinSameWiFi, .wakeHubMac])
    }

    func testLocalNetworkPermissionComesFirst() {
        var device = wifi
        device.isLocalNetworkDenied = true
        XCTAssertEqual(HubTroubleshooting.advice(for: home, on: device), [.allowLocalNetwork, .joinSameWiFi, .wakeHubMac])
    }

    func testAHubOnTailscaleSuggestsTurningItOn() {
        var device = wifi
        device.isOnWiFi = false
        XCTAssertEqual(HubTroubleshooting.advice(for: home + tailnet, on: device), [.joinSameWiFi, .connectTailscale, .wakeHubMac])
    }

    func testBothOnTailscaleLeavesTheWiFiOut() {
        var device = wifi
        device.isOnWiFi = false
        device.isOnTailnet = true
        XCTAssertEqual(HubTroubleshooting.advice(for: home + tailnet, on: device), [.wakeHubMac])
    }

    func testAHubThatAnswersNowOnlyNeedsTryingAgain() {
        var device = wifi
        device.isLocalNetworkDenied = true
        XCTAssertEqual(HubTroubleshooting.advice(for: home + tailnet, on: device, answered: [tailnet[0]]), [.tryAgain])
    }

    func testAHubWithoutAddressesOnlyAsksForTheMac() {
        XCTAssertEqual(HubTroubleshooting.advice(for: [], on: wifi), [.wakeHubMac])
    }
}
