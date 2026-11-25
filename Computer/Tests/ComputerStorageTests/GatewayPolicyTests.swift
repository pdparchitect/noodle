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
        let order = ["@deniedNetworks4", "@denied4", "@allowedNetworks4", "@allowed4", "log group 1 prefix \"gateway-drop \" drop"]
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

    /// Every verdict is logged once per connection or probe, without a rule allowing twice.
    func testEveryVerdictIsLoggedToUlogd() {
        let ruleset = GatewayConfiguration.ruleset(policy, slots: slots)
        XCTAssertTrue(ruleset.contains("ip daddr @denied4 log group 1 prefix \"gateway-deny \" drop"))
        XCTAssertTrue(ruleset.contains("ip daddr @allowed4 jump allow"))
        XCTAssertTrue(ruleset.contains("ct state new,invalid,untracked log group 1 prefix \"gateway-allow \"\n    accept"))
        XCTAssertTrue(ruleset.contains("log group 1 prefix \"gateway-drop \" drop"))
        XCTAssertTrue(GatewayConfiguration.ulogd.contains("file=\"/var/log/gateway.json\""))
    }

    func testFirewallLinesAreReadWithTheirVerdictAndComputer() {
        let log = """
            {"oob.prefix": "gateway-allow ", "oob.time.sec": 1795617733, "oob.time.usec": 500000, "ip.protocol": 6, "src_ip": "10.77.1.2", "dest_ip": "45.33.32.156", "dest_port": 80, "tcp.syn": 1, "tcp.ack": 0}
            {"oob.prefix": "gateway-deny ", "oob.time.sec": 1795617734, "ip.protocol": 6, "src_ip": "10.77.2.2", "dest_ip": "50.116.1.184", "dest_port": 443, "tcp.fin": 1}
            {"oob.prefix": "gateway-drop ", "oob.time.sec": 1795617735, "ip.protocol": 1, "src_ip": "10.77.1.2", "dest_ip": "1.1.1.1"}
            not json
            """
        let entries = GatewayFirewallEntry.parse(log, slots: slots)
        XCTAssertEqual(entries.map(\.verdict), [.allowed, .denied, .outsideScope])
        XCTAssertEqual(entries.map(\.slot), [1, 2, 1])
        XCTAssertEqual(entries.map(\.port), [80, 443, nil])
        XCTAssertEqual(entries.map(\.protocol), ["TCP", "TCP", "ICMP"])
        XCTAssertEqual(entries.map(\.flags), [["SYN"], ["FIN"], []])
        XCTAssertEqual(entries[0].time.timeIntervalSince1970, 1795617733.5, accuracy: 0.001)
    }

    /// Each lookup carries the answers that follow it, and its addresses are named after it.
    func testLookupsAreReadWithTheirAnswers() {
        let log = """
            Nov 25 14:42:14 dnsmasq[45]: query[A] example.com from 10.77.1.2
            Nov 25 14:42:14 dnsmasq[45]: forwarded example.com to 192.168.64.1
            Nov 25 14:42:14 dnsmasq[45]: reply example.com is 104.20.23.154
            Nov 25 14:42:14 dnsmasq[45]: reply example.com is 172.66.147.243
            Nov 25 14:42:15 dnsmasq[45]: query[AAAA] nowhere.invalid from 10.77.2.2
            Nov 25 14:42:15 dnsmasq[45]: reply nowhere.invalid is NXDOMAIN
            Nov 25 14:42:16 dnsmasq[45]: query[A] both.test from 10.77.1.2
            Nov 25 14:42:16 dnsmasq[45]: query[AAAA] both.test from 10.77.1.2
            Nov 25 14:42:16 dnsmasq[45]: reply both.test is 2001:db8::1
            Nov 25 14:42:16 dnsmasq[45]: reply both.test is 198.51.100.7
            """
        let (lookups, names) = GatewayLookup.parse(log, slots: slots, year: 2026)
        XCTAssertEqual(lookups.map(\.name), ["example.com", "nowhere.invalid", "both.test", "both.test"])
        XCTAssertEqual(lookups.map(\.slot), [1, 2, 1, 1])
        XCTAssertEqual(lookups.map(\.type), ["A", "AAAA", "A", "AAAA"])
        XCTAssertEqual(lookups[2].answers, ["198.51.100.7"], "an address goes to the query of its kind")
        XCTAssertEqual(lookups[3].answers, ["2001:db8::1"])
        XCTAssertEqual(lookups[0].answers, ["104.20.23.154", "172.66.147.243"])
        XCTAssertEqual(lookups[1].answers, ["NXDOMAIN"])
        XCTAssertEqual(names, ["104.20.23.154": "example.com", "172.66.147.243": "example.com", "198.51.100.7": "both.test"])
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: lookups[0].time),
                       DateComponents(year: 2026, month: 11, day: 25, hour: 14, minute: 42, second: 14))
    }

    /// A piece of log ends at its last whole line; the rest is read next time.
    func testLogsAreReadInWholeLines() {
        XCTAssertEqual(LogChunk.wholeLines("one\ntwo\nthr").text, "one\ntwo\n")
        XCTAssertEqual(LogChunk.wholeLines("one\ntwo\nthr").bytes, 8)
        XCTAssertEqual(LogChunk.wholeLines("partial").bytes, 0)
    }
}
