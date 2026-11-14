import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class ShodanTests: XCTestCase {
    private let connection = try! Shodan.preset.makeConnection(name: "Shodan")

    private func call(_ tool: String, _ arguments: String, on service: FakeService) async throws -> (text: String, isError: Bool, structured: [String: Any]?) {
        let data = try await Shodan.adapter.run(tool, arguments: Data(arguments.utf8), connection: connection, access: service)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? "", result["isError"] as? Bool ?? false,
                result["structuredContent"] as? [String: Any])
    }

    func testThePresetSendsItsKeyInTheAddress() {
        XCTAssertEqual(connection.endpoint.absoluteString, "https://api.shodan.io")
        XCTAssertEqual(connection.tokenParameter, "key")
        XCTAssertNil(connection.tokenHeader)
        XCTAssertEqual(connection.adapter, "shodan")
        XCTAssertNotNil(PionAdapters.all["shodan"])
    }

    func testAHostReportListsWhatIsExposed() async throws {
        let service = FakeService()
        service.answers["/shodan/host/203.0.113.77"] = (200, #"{"ip_str":"203.0.113.77","ports":[22,443],"hostnames":["mail.kestrel.example"],"org":"Example Hosting","isp":"Example ISP","asn":"AS64500","country_name":"Netherlands","city":"Amsterdam","os":null,"last_update":"2026-11-10T04:00:00.000000","vulns":["CVE-2024-6387"],"data":[{"port":22,"transport":"tcp","product":"OpenSSH","version":"9.6p1"},{"port":443,"transport":"tcp","product":"nginx"}]}"#)
        let host = try await call("host-report", #"{"ip":"203.0.113.77"}"#, on: service)
        XCTAssertFalse(host.isError, host.text)
        XCTAssertTrue(host.text.contains("22/tcp OpenSSH 9.6p1"), host.text)
        XCTAssertTrue(host.text.contains("CVE-2024-6387"), host.text)
        XCTAssertEqual(host.structured?["ports"] as? [Int], [22, 443])
        XCTAssertEqual(host.structured?["organisation"] as? String, "Example Hosting")
        XCTAssertEqual((host.structured?["services"] as? [[String: Any]])?.count, 2)
    }

    func testDNSLookupsBothWays() async throws {
        let service = FakeService()
        service.answers["/dns/resolve?hostnames=a.example,b.example"] = (200, #"{"a.example":"192.0.2.1","b.example":null}"#)
        service.answers["/dns/reverse?ips=192.0.2.1"] = (200, #"{"192.0.2.1":["a.example","alias.example"]}"#)
        let forward = try await call("dns-resolve", #"{"hostnames":["a.example","B.example"]}"#, on: service)
        XCTAssertFalse(forward.isError, forward.text)
        XCTAssertTrue(forward.text.contains("a.example → 192.0.2.1"), forward.text)
        let reverse = try await call("dns-reverse", #"{"ips":["192.0.2.1"]}"#, on: service)
        XCTAssertTrue(reverse.text.contains("alias.example"), reverse.text)
    }

    func testBadValuesAreRefusedBeforeAnythingIsSent() async throws {
        let service = FakeService()
        for (tool, arguments) in [("host-report", #"{"ip":"example.com"}"#), ("dns-resolve", #"{"hostnames":["bad host"]}"#),
                                  ("dns-resolve", #"{"hostnames":[]}"#), ("dns-reverse", #"{"ips":["1.2.3"]}"#)] {
            let result = try await call(tool, arguments, on: service)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }
}
