import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class CrowdSecTests: XCTestCase {
    private let connection = try! CrowdSec.cti.makeConnection(name: "CrowdSec CTI")

    private let seen = #"""
    {"ip":"203.0.113.77","reputation":"malicious","confidence":"high","background_noise":"high","ip_range":"203.0.113.0/24",
     "ip_range_score":4,"as_name":"Example Hosting","as_num":64500,"reverse_dns":"scan.example.net",
     "location":{"country":"NL","city":"Amsterdam"},
     "behaviors":[{"name":"ssh:bruteforce","label":"SSH Bruteforce","description":"…"},{"name":"http:scan","label":"HTTP Scan","description":"…"}],
     "attack_details":[{"name":"crowdsecurity/ssh-bf","label":"SSH Bruteforce","description":"…","references":[]}],
     "mitre_techniques":[{"name":"T1110","label":"Brute Force","description":"…"}],
     "classifications":{"classifications":[{"name":"proxy:tor","label":"TOR exit node","description":"…"}],"false_positives":[]},
     "cves":["CVE-2023-4966"],"history":{"first_seen":"2026-09-02T10:00:00","last_seen":"2026-11-17T22:15:00","full_age":77,"days_age":76},
     "scores":{"last_week":{"aggressiveness":5,"threat":4,"trust":5,"anomaly":1,"total":4}},
     "target_countries":{"US":40,"DE":25}}
    """#

    func testAnAddressSaysWhatCrowdSecsNetworkHasSeenItDo() async throws {
        XCTAssertEqual(connection.endpoint.absoluteString, "https://cti.api.crowdsec.net/v2")
        XCTAssertEqual(connection.tokenHeader, "x-api-key")
        XCTAssertNotNil(PionAdapters.all["crowdsec-cti"])
        let service = FakeService()
        service.answers["/v2/smoke/203.0.113.77"] = (200, seen)
        let result = try await callTool(CrowdSec.adapter, "ip", #"{"ip":"203.0.113.77"}"#, on: service, in: connection)
        XCTAssertFalse(result.isError, result.text)
        for expected in ["203.0.113.77: malicious (confidence high), background noise high",
                         "Example Hosting (AS64500)", "NL", "203.0.113.0/24",
                         "Behaviours: SSH Bruteforce, HTTP Scan", "Caught by: SSH Bruteforce",
                         "MITRE ATT&CK: T1110 Brute Force", "Classified: TOR exit node", "CVEs: CVE-2023-4966",
                         "First seen 2026-09-02T10:00:00, last seen 2026-11-17T22:15:00",
                         "Last week: aggressiveness 5, threat 4, trust 5, anomaly 1 (of 5)", "Targets: US, DE"] {
            XCTAssertTrue(result.text.contains(expected), "\(expected) missing from:\n\(result.text)")
        }

        let unseen = try await callTool(CrowdSec.adapter, "ip", #"{"ip":"192.0.2.1"}"#, on: service, in: connection)
        XCTAssertFalse(unseen.isError, "an address CrowdSec has not seen is a finding, not a failure")
        XCTAssertTrue(unseen.text.contains("has not seen 192.0.2.1"), unseen.text)
        let bad = try await callTool(CrowdSec.adapter, "ip", #"{"ip":"../smoke"}"#, on: service, in: connection)
        XCTAssertTrue(bad.isError)
    }

    func testSeveralAddressesAreLookedUpAtOnce() async throws {
        let service = FakeService()
        service.answers["/v2/smoke"] = (200, #"{"total":2,"not_found":1,"items":[\#(seen)]}"#)
        let result = try await callTool(CrowdSec.adapter, "ips", #"{"ips":["203.0.113.77","192.0.2.1"]}"#, on: service, in: connection)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(queryItems(service.requests.first)["ips"], "203.0.113.77,192.0.2.1")
        XCTAssertTrue(result.text.contains("203.0.113.77: malicious"), result.text)
        XCTAssertTrue(result.text.contains("Not seen: 192.0.2.1"), result.text)
        let tooMany = try await callTool(CrowdSec.adapter, "ips", #"{"ips":[\#((1...21).map { "\"192.0.2.\($0)\"" }.joined(separator: ","))]}"#,
                                         on: service, in: connection)
        XCTAssertTrue(tooMany.isError)
    }

    func testAKeyCrowdSecDoesNotKnowIsSaidToBeWrongNotShort() async throws {
        // CrowdSec's CTI answers 403 for a key it does not know.
        let service = FakeService()
        service.answers["/v2/smoke/203.0.113.77"] = (403, #"{"message":"Forbidden"}"#)
        let result = try await callTool(CrowdSec.adapter, "ip", #"{"ip":"203.0.113.77"}"#, on: service, in: connection)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("rejected this connection's credentials"), result.text)
    }

    func testCheckAccessTakesAnAddressCrowdSecHasNotSeenAsAWorkingKey() async throws {
        let service = FakeService()
        service.answers["/v2/smoke/192.0.2.1"] = (404, #"{"message":"IP address information not found"}"#)
        let access = try await callTool(CrowdSec.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("✓ API key: it works"), access.text)
        XCTAssertEqual(service.requests.count, 1)
    }

    func testCheckAccessSaysWhatToChangeForAKeyCrowdSecRefuses() async throws {
        let service = FakeService()
        service.answers["/v2/smoke/192.0.2.1"] = (403, #"{"message":"Forbidden"}"#)
        let access = try await callTool(CrowdSec.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertTrue(access.text.contains("✗ API key: CrowdSec did not accept the key"), access.text)
        XCTAssertTrue(access.text.contains("Settings › CTI API Keys"), access.text)
    }
}
