import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class NVDTests: XCTestCase {
    private let connection = try! NVD.preset.makeConnection(name: "NVD")
    /// A day within NVD's 120-day window whenever the tests run.
    private let since: String = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: "UTC"); format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Date().addingTimeInterval(-30 * 86_400))
    }()

    private static func cve(_ id: String, published: String, score: Double? = nil, severity: String? = nil, status: String = "Analyzed",
                            kev: (added: String, due: String)? = nil, text: String = "A flaw.") -> String {
        let metrics = score.map { #"{"cvssMetricV31":[{"type":"Primary","cvssData":{"baseScore":\#($0),"baseSeverity":"\#(severity ?? "HIGH")","vectorString":"CVSS:3.1/AV:N"}}]}"# } ?? "{}"
        let exploited = kev.map { #","cisaExploitAdd":"\#($0.added)","cisaActionDue":"\#($0.due)","cisaRequiredAction":"Apply the update.","cisaVulnerabilityName":"Example Flaw""# } ?? ""
        return #"{"cve":{"id":"\#(id)","published":"\#(published)T10:00:00.000","lastModified":"\#(published)T12:00:00.000","vulnStatus":"\#(status)","descriptions":[{"lang":"en","value":"\#(text)"}],"metrics":\#(metrics)\#(exploited),"weaknesses":[{"description":[{"lang":"en","value":"CWE-290"}]}],"configurations":[{"nodes":[{"cpeMatch":[{"vulnerable":true,"criteria":"cpe:2.3:a:grafana:grafana:*:*:*:*:enterprise:*:*:*","versionEndExcluding":"11.0.0"}]}]}],"references":[{"url":"https://grafana.com/security/security-advisories/\#(id.lowercased())"}]}}"#
    }

    func testAProductsNewCVEsComeNewestFirstWithTheirScoresAndWhetherTheyAreExploited() async throws {
        XCTAssertEqual(connection.endpoint.absoluteString, "https://services.nvd.nist.gov/rest/json")
        XCTAssertFalse(connection.keepsSecret, "NVD answers without a key")
        XCTAssertNotNil(PionAdapters.all["nvd"])
        let service = FakeService()
        // NVD lists oldest first, so the newest are on its last page.
        service.sequences["/rest/json/cves/2.0"] = [
            (200, #"{"totalResults":3,"startIndex":0,"vulnerabilities":[\#(Self.cve("CVE-2026-1001", published: "2026-09-01"))]}"#),
            (200, #"{"totalResults":3,"startIndex":1,"vulnerabilities":[\#(Self.cve("CVE-2026-1002", published: "2026-10-01", score: 9.8, severity: "CRITICAL", kev: ("2026-10-05", "2026-10-26"))),\#(Self.cve("CVE-2026-1003", published: "2026-11-01", status: "Awaiting Analysis"))]}"#),
        ]
        let result = try await callTool(NVD.adapter, "recent", #"{"product":"grafana:grafana","since":"\#(since)","severity":"CRITICAL","limit":2}"#,
                                        on: service, in: connection)
        XCTAssertFalse(result.isError, result.text)
        let lines = result.text.split(separator: "\n")
        XCTAssertTrue(lines.first?.hasPrefix("CVE-2026-1003") == true, result.text)
        XCTAssertTrue(result.text.contains("CVE-2026-1002 (published 2026-10-01, CRITICAL 9.8, exploited: CISA added it 2026-10-05, fix by 2026-10-26)"), result.text)
        XCTAssertTrue(result.text.contains("awaiting NVD's analysis"), result.text)
        XCTAssertFalse(result.text.contains("CVE-2026-1001"), "an older one was shown in place of a newer one")
        let first = queryItems(service.requests.first), second = queryItems(service.requests.last)
        XCTAssertEqual(first["virtualMatchString"], "cpe:2.3:*:grafana:grafana")
        XCTAssertEqual(first["pubStartDate"], since + "T00:00:00.000Z")
        XCTAssertEqual(first["cvssV3Severity"], "CRITICAL")
        XCTAssertNotNil(first["noRejected"])
        XCTAssertEqual(second["startIndex"], "1", "the newest page was not asked for")

        for bad in [#"{}"#, #"{"product":"grafana"}"#, #"{"product":"grafana:grafana","since":"2020-01-01"}"#,
                    #"{"keyword":"sentry","severity":"BAD"}"#, #"{"keyword":"sentry","limit":500}"#] {
            let refused = try await callTool(NVD.adapter, "recent", bad, on: FakeService(), in: connection)
            XCTAssertTrue(refused.isError, bad)
        }
    }

    func testOneCVEInFull() async throws {
        let service = FakeService()
        service.answers["/rest/json/cves/2.0"] = (200, #"{"totalResults":1,"vulnerabilities":[\#(Self.cve("CVE-2026-14199", published: "2026-09-02", score: 7.1, kev: ("2026-11-04", "2026-11-18"), text: "Only self-managed Grafana with Auth Proxy is affected."))]}"#)
        let result = try await callTool(NVD.adapter, "cve", #"{"id":"cve-2026-14199"}"#, on: service, in: connection)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(queryItems(service.requests.first)["cveId"], "CVE-2026-14199")
        for expected in ["CVE-2026-14199", "HIGH 7.1", "CWE-290", "Exploited: CISA added it 2026-11-04", "fix by 2026-11-18", "Apply the update.",
                         "Only self-managed Grafana", "cpe:2.3:a:grafana:grafana:*:*:*:*:enterprise:*:*:* before 11.0.0",
                         "https://grafana.com/security/security-advisories/cve-2026-14199"] {
            XCTAssertTrue(result.text.contains(expected), "\(expected) missing from:\n\(result.text)")
        }
        service.answers["/rest/json/cves/2.0"] = (200, #"{"totalResults":0,"vulnerabilities":[]}"#)
        let unknown = try await callTool(NVD.adapter, "cve", #"{"id":"CVE-2026-99999"}"#, on: service, in: connection)
        XCTAssertFalse(unknown.isError)
        XCTAssertTrue(unknown.text.contains("NVD has no CVE-2026-99999"), unknown.text)
        let bad = try await callTool(NVD.adapter, "cve", #"{"id":"../cpes"}"#, on: service, in: connection)
        XCTAssertTrue(bad.isError)
    }

    func testWhatCISAHasLatelyFoundExploitedComesNewestFirst() async throws {
        let service = FakeService()
        service.answers["/rest/json/cves/2.0"] = (200, #"{"totalResults":2,"vulnerabilities":[\#(Self.cve("CVE-2024-27834", published: "2024-05-01", kev: ("2026-10-28", "2026-11-18"))),\#(Self.cve("CVE-2026-46300", published: "2026-10-01", kev: ("2026-11-04", "2026-11-25")))]}"#)
        let result = try await callTool(NVD.adapter, "exploited", #"{"since":"\#(since)"}"#, on: service, in: connection)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.hasPrefix("CVE-2026-46300"), result.text)
        XCTAssertTrue(result.text.contains("CISA added it 2026-10-28, fix by 2026-11-18"), result.text)
        let sent = queryItems(service.requests.first)
        XCTAssertNotNil(sent["hasKev"])
        XCTAssertEqual(sent["kevStartDate"], since + "T00:00:00.000Z")
    }

    func testAProductIsFoundByNameAsNVDKnowsIt() async throws {
        let service = FakeService()
        service.answers["/rest/json/cpes/2.0"] = (200, #"""
        {"totalResults":3,"products":[{"cpe":{"cpeName":"cpe:2.3:a:grafana:grafana:4.6.0:*:*:*:*:*:*:*","titles":[{"title":"Grafana 4.6.0","lang":"en"}]}},
          {"cpe":{"cpeName":"cpe:2.3:a:grafana:grafana:4.6.1:*:*:*:*:*:*:*","titles":[{"title":"Grafana 4.6.1","lang":"en"}]}},
          {"cpe":{"cpeName":"cpe:2.3:a:grafana:loki:2.0.0:*:*:*:*:*:*:*","titles":[{"title":"Grafana Loki 2.0.0","lang":"en"}]}}]}
        """#)
        let result = try await callTool(NVD.adapter, "products", #"{"query":"grafana"}"#, on: service, in: connection)
        XCTAssertEqual(result.text, "grafana:grafana (application), such as Grafana 4.6.0\ngrafana:loki (application), such as Grafana Loki 2.0.0")
        XCTAssertEqual(queryItems(service.requests.first)["keywordSearch"], "grafana")
    }

    func testBeingLimitedSaysToWaitRatherThanBlamingAKey() async throws {
        let service = FakeService()
        service.answers["/rest/json/cves/2.0"] = (403, "")
        let result = try await callTool(NVD.adapter, "cve", #"{"id":"CVE-2026-14199"}"#, on: service, in: connection)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("five requests in 30 seconds"), result.text)
    }
}
