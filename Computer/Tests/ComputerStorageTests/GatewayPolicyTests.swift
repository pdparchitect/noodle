@testable import ComputerEngine
import XCTest

final class GatewayPolicyTests: XCTestCase {
    private let slots = [GatewaySlot(index: 1, outsideAddress: "192.168.64.254"), GatewaySlot(index: 2, outsideAddress: "192.168.64.253")]
    private let policy = GatewayPolicy(
        allowed: [.domain("target.com"), .address("198.51.100.7"), .network("203.0.113.9", prefix: 24), .domain("target.com"),
                  .address("2001:db8::1")],
        denied: [.domain("payments.target.com"), .network("203.0.113.128", prefix: 25)])

    /// Everything not allowed is dropped; deny comes before allow; each computer leaves under its own address.
    func testTheRulesetDropsByDefaultAndDenyWins() {
        let ruleset = GatewayConfiguration.ruleset(policy, slots: slots)
        XCTAssertTrue(ruleset.hasPrefix("flush ruleset\ntable inet gateway {"))
        XCTAssertTrue(ruleset.contains("set allowedNetworks4 { type ipv4_addr; flags interval; auto-merge; elements = { 198.51.100.7/32, 203.0.113.0/24 }; }"), ruleset)
        XCTAssertTrue(ruleset.contains("set deniedNetworks4 { type ipv4_addr; flags interval; auto-merge; elements = { 203.0.113.128/25 }; }"), ruleset)
        XCTAssertTrue(ruleset.contains("type filter hook forward priority filter; policy drop;"))
        let order = ["@deniedNetworks4", "@denied4", "@allowedNetworks4", "@allowed4", "log prefix \"gateway-drop \" drop"]
            .map { ruleset.range(of: $0)!.lowerBound }
        XCTAssertEqual(order, order.sorted(), "deny before allow, and the drop last")
        for slot in slots {
            XCTAssertTrue(ruleset.contains("ip saddr \(slot.computerAddress) snat ip to \(slot.outsideAddress)"))
            XCTAssertTrue(ruleset.contains("ct state invalid,untracked ip saddr \(slot.computerAddress) ip saddr set \(slot.outsideAddress)"))
            XCTAssertTrue(ruleset.contains("ct state invalid,untracked ip daddr \(slot.outsideAddress) ip daddr set \(slot.computerAddress)"))
        }
        XCTAssertFalse(ruleset.contains("2001:db8"), "IPv6 is dropped, never listed")
    }

    func testAnEmptyPolicyStillLoadsAndDropsEverything() {
        let ruleset = GatewayConfiguration.ruleset(GatewayPolicy(), slots: [])
        XCTAssertTrue(ruleset.contains("set allowedNetworks4 { type ipv4_addr; flags interval; auto-merge; }"))
        XCTAssertTrue(ruleset.contains("policy drop;"))
    }

    func testDNSFillsTheSetsForEachNameOnce() {
        let config = GatewayConfiguration.dnsmasq(policy, slots: slots, upstream: "192.168.64.1")
        XCTAssertEqual(config.split(separator: "\n").filter { $0.hasPrefix("nftset=") },
                       ["nftset=/target.com/4#inet#gateway#allowed4", "nftset=/payments.target.com/4#inet#gateway#denied4"])
        XCTAssertTrue(config.contains("server=192.168.64.1\n"))
        XCTAssertTrue(config.contains("except-interface=eth0\n"), "never answers NAT's side")
    }

    func testDropsAreReadBackWithTheComputerThatSentThem() {
        let log = """
            [  41.2] gateway-drop IN=eth1 OUT=eth0 SRC=10.77.1.2 DST=1.1.1.1 LEN=84 TTL=63 PROTO=ICMP TYPE=8 CODE=0
            [  42.0] gateway-deny IN=eth2 OUT=eth0 SRC=10.77.2.2 DST=50.116.1.184 LEN=60 PROTO=TCP SPT=40000 DPT=443 SYN
            [  43.0] something else entirely
            """
        XCTAssertEqual(GatewayEvent.parse(kernelLog: log, slots: slots), [
            .blocked(slot: 1, destination: "1.1.1.1", port: nil, protocol: "ICMP", denied: false),
            .blocked(slot: 2, destination: "50.116.1.184", port: 443, protocol: "TCP", denied: true),
        ])
    }
}
