import Foundation
import NoodleCore
@testable import PionCore
import XCTest

/// Hunt.io's answers here follow the examples in its OpenAPI spec at a.hunt.io/openapi.json.
final class HuntIOTests: XCTestCase {
    private let huntio = try! HuntIO.preset.makeConnection(name: "Hunt.io Detection")
    private static let meta = #""meta":{"authz":{"endpoint":"/x","orgId":"org_kestrel","plan":"researcher","quota":{"limit":10000,"remaining":9958,"used":42}}}"#

    private func ok(_ data: String) -> (Int, String) { (200, #"{"ok":true,"data":"# + data + "," + Self.meta + "}") }

    /// What a request sent, as JSON.
    private func body(_ request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as? [String: Any])
    }

    private func request(_ service: FakeService, _ path: String) -> URLRequest? { service.requests.last { $0.url?.path == path } }

    func testDetectionReadsWithABearerKeyAndTheMCPServerTakesAKeyOfItsOwn() async throws {
        XCTAssertEqual(HuntIO.preset.name, "Hunt.io Detection")
        XCTAssertEqual(huntio.endpoint.absoluteString, "https://a.hunt.io")
        XCTAssertEqual(huntio.tokenHeader, "Authorization")
        XCTAssertEqual(huntio.tokenScheme, "Bearer")
        XCTAssertEqual(huntio.adapter, "huntio")
        XCTAssertNotNil(PionAdapters.all["huntio"])
        XCTAssertNil(HuntIO.adapter.watchedTool, "Hunt.io has no feed of an organisation's own alerts to watch")

        XCTAssertEqual(HuntIO.mcp.name, "Hunt.io")
        guard case .connection(let mcp) = HuntIO.mcp.configuration else { return XCTFail("no connection") }
        XCTAssertEqual(mcp.endpoint.absoluteString, "https://mcp.hunt.io/mcp")
        XCTAssertEqual(mcp.tokenHeader, "Authorization")
        XCTAssertEqual(mcp.tokenScheme, "Bearer")
        XCTAssertNil(mcp.oauth, "Hunt.io's MCP sign-in needs a client secret, which Pion does not ship")
        XCTAssertNil(HuntIO.mcp.adapter)
        XCTAssertTrue(HuntIO.mcp.needsSetUp)
        let server = try HuntIO.mcp.makeConnection(name: "Hunt.io")
        XCTAssertEqual(server.tokenHeader, "Authorization")
        XCTAssertEqual(server.tokenScheme, "Bearer")
        XCTAssertTrue(HuntIO.mcpSetup.joined().contains("dedicated MCP key"))
        XCTAssertTrue(HuntIO.mcp.defaultInstructions.contains("Never download"))
        for id in [HuntIO.preset.id, HuntIO.mcp.id] { XCTAssertTrue(PionCatalogue.entries.contains { $0.id == id }, id) }
        XCTAssertTrue(HuntIO.setup.joined().contains("no free plan"))

        let listed = try JSONSerialization.jsonObject(with: try await HuntIO.adapter.tools(for: huntio)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["ip-lookup", "domain-lookup", "certificate-lookup", "ioc-hunter-search", "attackcapture-host", "threat-actors", "check-access"])
        for tool in tools {
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true, "\(tool["name"] ?? "")")
        }
        for operation in HuntIO.operations { XCTAssertEqual(type(of: operation).jobs, [.detection], type(of: operation).name) }
    }

    func testAnAddressLeadsWithItsMalwareReportsAndActorThenItsNetwork() async throws {
        let service = FakeService()
        service.answers["/search/ip/risk"] = ok(#"{"iocs":[{"malware_name":"CobaltStrike","post_id":12345,"published_at":"2026-01-10","title":"CobaltStrike C2 infrastructure","url":"https://ioc-hunter.hunt.io/post/12345"}],"ip":"45.133.180.26","malicious_open_dirs":[],"malware_names":["CobaltStrike"],"ok":true,"piocs":[],"summary":{"high_risk":1,"warning":1},"threat_actor":{"name":"APT28","source":"IOC Hunter"},"tor_detected":false,"vpn_service":null}"#)
        service.answers["/enrichment/ip"] = ok(#"{"ok":true,"ip":"45.133.180.26","timeframeDays":30,"row":{"asn.domain":"example-hosting.net","asn.name":"EXAMPLE-HOSTING","asn.number":64500,"ip":"45.133.180.26","services":[{"service.last_seen":"2026-03-22T10:00:00Z","service.port":443,"malware.name":"Cobalt Strike"},{"service.last_seen":"2026-03-10T10:00:00Z","service.port":53}],"timestamp":"2026-03-24T12:00:00Z"}}"#)
        let found = try await callTool(HuntIO.adapter, "ip-lookup", #"{"ip":"45.133.180.26","days":30}"#, on: service, in: huntio)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.hasPrefix("45.133.180.26: Hunt.io saw malware or C2 on it: CobaltStrike."), found.text)
        XCTAssertTrue(found.text.contains("Linked to threat actor APT28"), found.text)
        XCTAssertTrue(found.text.contains("\"CobaltStrike C2 infrastructure\" (2026-01-10)"), found.text)
        XCTAssertTrue(found.text.contains("EXAMPLE-HOSTING, AS64500"), found.text)
        XCTAssertTrue(found.text.contains("port 53, last seen 2026-03-10; port 443, Cobalt Strike malware"), found.text)
        XCTAssertEqual(found.structured?["threatReportCount"] as? Int, 1)

        let risk = request(service, "/search/ip/risk"), enrichment = request(service, "/enrichment/ip")
        XCTAssertEqual(risk?.httpMethod, "POST")
        XCTAssertEqual(risk?.url?.host, "a.hunt.io")
        XCTAssertEqual(try body(risk) as NSDictionary, ["ip": "45.133.180.26"])
        XCTAssertEqual(try body(enrichment) as NSDictionary, ["ip": "45.133.180.26", "timeframeDays": 30])
        XCTAssertEqual(enrichment?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json"), true)

        let six = try await callTool(HuntIO.adapter, "ip-lookup", #"{"ip":"2001:db8::1"}"#, on: service, in: huntio)
        XCTAssertTrue(six.isError)
        XCTAssertTrue(six.text.contains("IPv4"), six.text)
    }

    func testAnAddressHuntIOHasNoRecordOfIsAFindingNotAFailure() async throws {
        let service = FakeService()
        service.answers["/search/ip/risk"] = ok(#"{"iocs":[],"ip":"192.0.2.1","malicious_open_dirs":[],"malware_names":[],"ok":true,"piocs":[],"summary":{"high_risk":0,"warning":0},"threat_actor":null,"tor_detected":false,"vpn_service":null}"#)
        service.answers["/enrichment/ip"] = ok(#"{"ok":true,"ip":"192.0.2.1","timeframeDays":45,"row":null}"#)
        let clean = try await callTool(HuntIO.adapter, "ip-lookup", #"{"ip":"192.0.2.1"}"#, on: service, in: huntio)
        XCTAssertFalse(clean.isError, clean.text)
        XCTAssertTrue(clean.text.contains("has no malware, C2, threat report"), clean.text)
        XCTAssertTrue(clean.text.contains("no scan record of it in the last 45 days"), clean.text)

        let empty = FakeService()

        empty.answers["/attackcapture/host/summary"] = ok(#"{"ok":false,"error":{"code":"not_found","message":"Host not found"}}"#)
        let directory = try await callTool(HuntIO.adapter, "attackcapture-host", #"{"host":"http://192.0.2.2:8080"}"#, on: empty, in: huntio)
        XCTAssertFalse(directory.isError, directory.text)
        XCTAssertTrue(directory.text.contains("has no record of an open directory at http://192.0.2.2:8080"), directory.text)

        empty.answers["/intel/certificate/details"] = ok(#"{"ok":true,"row":null}"#)
        let certificate = try await callTool(HuntIO.adapter, "certificate-lookup", #"{"sha256":"\#(String(repeating: "a", count: 64))"}"#, on: empty, in: huntio)
        XCTAssertFalse(certificate.isError, certificate.text)
        XCTAssertTrue(certificate.text.contains("has no record of the certificate"), certificate.text)
    }

    /// A 404 means no endpoint matched, so it is an error, never "no record": silence is not proof.
    func testA404IsAnErrorNotAMissingRecord() async throws {
        let service = FakeService()
        service.answers["/search/ip/risk"] = (404, #"{"ok":false,"error":{"code":"not_found","message":"No endpoint matches"}}"#)
        let result = try await callTool(HuntIO.adapter, "ip-lookup", #"{"ip":"192.0.2.2"}"#, on: service, in: huntio)
        XCTAssertTrue(result.isError, result.text)
        XCTAssertFalse(result.text.contains("has no record"), result.text)

        let unanswered = try await callTool(HuntIO.adapter, "domain-lookup", #"{"domain":"example.com"}"#, on: FakeService(), in: huntio)
        XCTAssertTrue(unanswered.isError, unanswered.text)
    }

    func testAQuotaSpentOrARateLimitIsSaidPlainly() async throws {
        let service = FakeService()
        service.answers["/search/ip/risk"] = (429, #"{"ok":false,"error":{"code":"quota_exceeded","message":"Usage limit exhausted for the current period","requestId":"req_1"}}"#)
        let spent = try await callTool(HuntIO.adapter, "ip-lookup", #"{"ip":"203.0.113.7"}"#, on: service, in: huntio)
        XCTAssertTrue(spent.isError)
        XCTAssertTrue(spent.text.contains("quota for this month is used up"), spent.text)
        XCTAssertTrue(spent.text.contains("quota_exceeded"), spent.text)
        XCTAssertEqual(service.requests.filter { $0.url?.path == "/enrichment/ip" }.count, 0, "nothing more is asked once the quota is spent")

        service.answers["/enrichment/domain"] = (429, #"{"ok":false,"error":{"code":"rate_limited","message":"Rate limit exceeded","requestId":"req_2"}}"#)
        let slowed = try await callTool(HuntIO.adapter, "domain-lookup", #"{"domain":"example.com"}"#, on: service, in: huntio)
        XCTAssertTrue(slowed.isError)
        XCTAssertTrue(slowed.text.contains("rate limiting"), slowed.text)

        service.answers["/threat-actors/listing/search"] = (403, #"{"ok":false,"error":{"code":"operation_not_allowed","message":"Operation not allowed","requestId":"req_3"}}"#)
        let plan = try await callTool(HuntIO.adapter, "threat-actors", #"{"query":"APT28"}"#, on: service, in: huntio)
        XCTAssertTrue(plan.isError)
        XCTAssertTrue(plan.text.contains("plan may not include this lookup"), plan.text)

        service.answers["/usage/monthly"] = (401, #"{"ok":false,"error":{"code":"unauthorized","message":"Unauthorized","requestId":"req_4"}}"#)
        let wrong = try await callTool(HuntIO.adapter, "check-access", "{}", on: service, in: huntio)
        XCTAssertTrue(wrong.isError)
        XCTAssertTrue(wrong.text.contains("rejected this connection's credentials"), wrong.text)
    }

    func testADomainsDNSWhoisAndSubdomains() async throws {
        let service = FakeService()
        service.answers["/enrichment/domain"] = ok(#"{"domain":"portal.suspicious-update-service.com","ok":true,"results":{"domain":{"apex_domain":"suspicious-update-service.com","dns":{"a":["198.51.100.24"]}},"subdomains":{"subdomains":["api","panel","download"]},"whois":{"CreateDate":"2025-12-03","DomainRegistrarName":"Namecheap","UpdateDate":"2026-02-11","whois_source":"internal_crawler"}},"upstream":{"domain":200,"subdomains":200,"whois":200,"tags":502}}"#)
        let found = try await callTool(HuntIO.adapter, "domain-lookup", #"{"domain":"Portal.Suspicious-Update-Service.com"}"#, on: service, in: huntio)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("(apex suspicious-update-service.com)"), found.text)
        XCTAssertTrue(found.text.contains("resolves to 198.51.100.24"), found.text)
        XCTAssertTrue(found.text.contains("registrar Namecheap, created 2025-12-03"), found.text)
        XCTAssertTrue(found.text.contains("3 subdomains: api, panel, download"), found.text)
        XCTAssertTrue(found.text.contains("could not read tags (502)"), found.text)
        XCTAssertEqual(try body(request(service, "/enrichment/domain")) as NSDictionary, ["domain": "portal.suspicious-update-service.com"])
    }

    func testACertificateByItsFingerprint() async throws {
        let service = FakeService()
        service.answers["/intel/certificate/details"] = ok(#"{"ok":true,"row":{"dns_names":["api.panel-update-check.net","panel-update-check.net"],"is_ca":false,"issuer_common_name":"R10","key_usage":["digitalSignature","keyEncipherment"],"not_after":"2026-04-29 23:59:59","not_before":"2026-01-30 00:00:00","seen_first":"2026-01-18 21:33:00","seen_last":"2026-02-17 13:04:11","serial":"4f2a9e7d","sha256_hash":"B1946AC92492D2347C6235B4D2611184D7A9D5F5B5D3F7E9F2A0B8C7D6E5F4A3","signature_algorithm":"SHA256-RSA","subject_common_name":"panel-update-check.net","version":3}}"#)
        let found = try await callTool(HuntIO.adapter, "certificate-lookup",
                                       #"{"sha256":"B1946AC92492D2347C6235B4D2611184D7A9D5F5B5D3F7E9F2A0B8C7D6E5F4A3"}"#, on: service, in: huntio)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("panel-update-check.net, for api.panel-update-check.net, panel-update-check.net, issued by R10"), found.text)
        XCTAssertTrue(found.text.contains("first saw it 2026-01-18, last 2026-02-17"), found.text)
        XCTAssertEqual(try body(request(service, "/intel/certificate/details")) as NSDictionary,
                       ["sha256_hash": "b1946ac92492d2347c6235b4d2611184d7a9d5f5b5d3f7e9f2a0b8c7d6e5f4a3"])
        let short = try await callTool(HuntIO.adapter, "certificate-lookup", #"{"sha256":"abc"}"#, on: service, in: huntio)
        XCTAssertTrue(short.isError)
    }

    func testIOCHunterSearchesReportsByAddressHostOrActorsHashes() async throws {
        let service = FakeService()
        service.answers["/search/ioc-hunter/ip"] = ok(#"{"ok":true,"rows":[{"adversary":"APT28","created_at":"2025-02-20 15:00:00","hosting_company":"OVH","hosting_company_domain":"ovh.net","ip":"198.51.100.32","post_adversary_synonyms":["Fancy Bear"],"post_deleted_at":null,"post_description":"Research linking the address to an active campaign.","post_domain":"threat-post.stream","post_id":"2001","post_ioc_sha256":["54e9bb32b2168a8756a30a179e2cbd88cd7bff51835d0693203176470d1fd8a9"],"post_malware_family":["Cobalt Strike"],"post_malware_name":"Cobalt Strike","post_published_at":"2025-02-20 14:30:00","post_title":"APT28 command-and-control infrastructure","post_url":"https://threat-post.stream/reports/2001","post_verified":1,"source":"Threat Post Stream","source_domain":"threat-post.stream"}],"total":318}"#)
        let byIP = try await callTool(HuntIO.adapter, "ioc-hunter-search", #"{"kind":"ip","netblock":"198.51.100.0/24","adversary":"APT28","limit":1}"#,
                                      on: service, in: huntio)
        XCTAssertFalse(byIP.isError, byIP.text)
        XCTAssertTrue(byIP.text.contains("318 ip reports for 198.51.100.0/24, actor APT28; the first 1:"), byIP.text)
        XCTAssertTrue(byIP.text.contains("· 198.51.100.32: APT28, Cobalt Strike — \"APT28 command-and-control infrastructure\" (Threat Post Stream, 2025-02-20)"), byIP.text)
        XCTAssertEqual(byIP.structured?["truncated"] as? Bool, true)
        XCTAssertEqual(try body(request(service, "/search/ioc-hunter/ip")) as NSDictionary,
                       ["includeRows": true, "includeTotal": true, "includeFacets": false, "limit": 1, "offset": 0,
                        "netblock": "198.51.100.0/24", "adversaries": ["APT28"]])

        service.answers["/search/ioc-hunter/host"] = ok(#"{"ok":true,"rows":[{"adversary":"APT41","created_at":"2025-02-20 15:00:00","has_ioc_sha256":0,"post_description":"Research linking the host to an active campaign.","post_domain":"threat-post.stream","post_id":"2001","post_malware_family":["Cobalt Strike"],"post_published_at":"2025-02-20 14:30:00","post_title":"APT41 command-and-control infrastructure","post_url":"https://threat-post.stream/reports/2001","source":"Threat Post Stream","source_domain":"intelstream.zone","url":"panel-operator-control.net"}],"total":1}"#)
        let byHost = try await callTool(HuntIO.adapter, "ioc-hunter-search", #"{"kind":"host","domain":"panel-operator-control.net","days":30}"#,
                                        on: service, in: huntio)
        XCTAssertFalse(byHost.isError, byHost.text)
        XCTAssertTrue(byHost.text.contains("· panel-operator-control.net: APT41"), byHost.text)
        let host = try body(request(service, "/search/ioc-hunter/host"))
        XCTAssertEqual(host["domainKeyword"] as? String, "panel-operator-control.net")
        let after = try XCTUnwrap(host["createdAfterMs"] as? Double)
        XCTAssertEqual(after / 1000, Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970, accuracy: 60)
        XCTAssertNil(host["ip"])

        service.answers["/search/ioc-hunter/sha256"] = ok(#"{"ok":true,"rows":[],"total":0}"#)
        let none = try await callTool(HuntIO.adapter, "ioc-hunter-search", #"{"kind":"sha256","malwareFamily":"Cobalt Strike"}"#, on: service, in: huntio)
        XCTAssertFalse(none.isError, none.text)
        XCTAssertTrue(none.text.contains("has no sha256 reports for malware Cobalt Strike"), none.text)
        XCTAssertEqual(try body(request(service, "/search/ioc-hunter/sha256"))["malwareFamilies"] as? [String], ["Cobalt Strike"])

        let mixed = try await callTool(HuntIO.adapter, "ioc-hunter-search", #"{"kind":"sha256","ip":"198.51.100.32"}"#, on: service, in: huntio)
        XCTAssertTrue(mixed.isError, "a hash search takes no address")
    }

    func testAnOpenDirectorysSummaryWithoutItsFiles() async throws {
        let service = FakeService()
        service.answers["/attackcapture/host/summary"] = ok(#"{"data":{"downloadAvailable":true,"numSubdirs":44,"seenFirst":"2026-01-29 03:20:15","totalItems":812,"totalSize":12883012},"ok":true}"#)
        let found = try await callTool(HuntIO.adapter, "attackcapture-host", #"{"host":"http://80.225.214.48:8082"}"#, on: service, in: huntio)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("first seen 2026-01-29, holding 812 items in 44 folders"), found.text)
        XCTAssertNil(found.structured?["downloadAvailable"], "nothing invites a download")
        XCTAssertEqual(try body(request(service, "/attackcapture/host/summary")) as NSDictionary, ["hostname": "http://80.225.214.48:8082"])
        XCTAssertFalse(service.requests.contains { $0.url?.path.contains("download") == true })
    }

    func testThreatActorsByNameOrCountry() async throws {
        let service = FakeService()
        service.answers["/threat-actors/listing/search"] = ok(#"{"ok":true,"rows":[{"country":"United States","country_code":"US","description":null,"headline":"Credential theft with rotating infrastructure","id":"3944","ioc_host_count":"24","ioc_ip_count":"68","ioc_sha256_count":"9","latest_ioc_date":"2025-02-23","latest_post_date":"2025-02-22","meta_category":["Credential Theft"],"meta_incident":[],"meta_victims":["Financial Sector"],"name":"UNC3944","origin":"UNC3944","pioc_host_count":"7","pioc_ip_count":"12","post_count":"124","ransomware_group":null,"security_company":"Aureon Security Labs","security_company_url":"https://aureonsecuritylabs.com","synonyms":[["Scattered Spider",null,null]],"uuid":"ta-unc-3944"}],"total":1}"#)
        let found = try await callTool(HuntIO.adapter, "threat-actors", #"{"query":"UNC3944","country":"us"}"#, on: service, in: huntio)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("· UNC3944 (also Scattered Spider), United States: Credential theft with rotating infrastructure"), found.text)
        XCTAssertTrue(found.text.contains("Linked to 68 IP addresses, 24 hosts, 9 file hashes, latest 2025-02-23"), found.text)
        XCTAssertTrue(found.text.contains("Victims: Financial Sector"), found.text)
        XCTAssertEqual(try body(request(service, "/threat-actors/listing/search")) as NSDictionary,
                       ["q": "UNC3944", "countryCodes": ["US"], "includeRows": true, "includeTotal": true, "includeFacets": false, "limit": 5, "offset": 0])
        let nothing = try await callTool(HuntIO.adapter, "threat-actors", "{}", on: service, in: huntio)
        XCTAssertTrue(nothing.isError)
    }

    func testCheckAccessShowsThePlanAndTheQuotaLeft() async throws {
        let service = FakeService()
        service.answers["/usage/monthly"] = ok(#"{"limit":1000,"period":"2026-11","remaining":958,"used":42}"#)
        let access = try await callTool(HuntIO.adapter, "check-access", "{}", on: service, in: huntio)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("for Hunt.io organisation org_kestrel on the researcher plan"), access.text)
        XCTAssertTrue(access.text.contains("In 2026-11: 42 of 1000 requests used, 958 left."), access.text)
        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(service.requests.first?.httpMethod, "GET")
        XCTAssertEqual(service.requests.first?.url?.absoluteString, "https://a.hunt.io/usage/monthly")
    }

    func testALowQuotaIsMentioned() async throws {
        let service = FakeService()
        service.answers["/attackcapture/host/summary"] = (200, #"{"ok":true,"data":{"data":{"numSubdirs":1,"seenFirst":"2026-01-29 03:20:15","totalItems":3},"ok":true},"meta":{"authz":{"endpoint":"/attackcapture/host/summary","orgId":"org_kestrel","quota":{"limit":1000,"remaining":12,"used":988}}}}"#)
        let found = try await callTool(HuntIO.adapter, "attackcapture-host", #"{"host":"198.51.100.9"}"#, on: service, in: huntio)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.hasSuffix("Only 12 of the 1000 requests in Hunt.io's quota are left."), found.text)
    }
}
