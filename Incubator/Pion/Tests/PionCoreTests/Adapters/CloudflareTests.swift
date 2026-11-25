import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import Synchronization
import XCTest

final class CloudflareTests: XCTestCase {
    static let accountID = "023e105f4ecef8ad9ca31a8372d0c353"
    static let zoneID = "4b2f1a0c9d8e7f6a5b4c3d2e1f0a9b8c"
    static let clientID = "54d11594-84e4-41aa-b438-e81b8fa78ee7"
    private let cloudflare = try! Cloudflare.preset.makeConnection(name: "Cloudflare — Kestrel", values: ["account": CloudflareTests.accountID, "clientID": CloudflareTests.clientID])
    private let account = "/client/v4/accounts/\(CloudflareTests.accountID)"

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await Cloudflare.$pause.withValue({ _ in }) { try await callTool(Cloudflare.adapter, tool, arguments, on: service, in: cloudflare) }
    }

    /// The zone lookup every zone's read starts with.
    static func zone(_ service: FakeService) {
        service.answers["/client/v4/zones"] = (200, #"{"success":true,"errors":[],"result":[{"id":"\#(zoneID)","name":"kestrel.example","status":"active"}],"result_info":{"page":1,"per_page":50,"count":1,"total_count":1,"total_pages":1}}"#)
    }

    static func page(_ items: String, page: Int = 1, perPage: Int = 50, count: Int? = nil, total: Int? = nil, totalPages: Int? = nil) -> (Int, String) {
        var info = [#""page":\#(page)"#, #""per_page":\#(perPage)"#]
        if let count { info.append(#""count":\#(count)"#) }
        if let total { info.append(#""total_count":\#(total)"#) }
        if let totalPages { info.append(#""total_pages":\#(totalPages)"#) }
        return (200, #"{"success":true,"errors":[],"messages":[],"result":[\#(items)],"result_info":{\#(info.joined(separator: ","))}}"#)
    }

    func testDetectionIsItsOwnReadOnlyToolSignedInThroughOAuthAndRadarStaysApart() async throws {
        XCTAssertEqual(Cloudflare.preset.name, "Cloudflare Detection")
        XCTAssertEqual(Cloudflare.preset.id, "a975fdab-e1f0-486c-abf6-d941d667d6f7", "the catalogue entry keeps its ID")
        XCTAssertEqual(cloudflare.endpoint.absoluteString, "https://api.cloudflare.com/client/v4")
        XCTAssertNil(cloudflare.tokenHeader, "no API token: it signs in through OAuth")
        XCTAssertNil(cloudflare.tokenScheme)
        XCTAssertFalse(cloudflare.keepsSecret)
        XCTAssertEqual(cloudflare.settings?["clientID"], Self.clientID)
        XCTAssertEqual(cloudflare.settings?["account"], Self.accountID)
        XCTAssertEqual(cloudflare.adapter, "cloudflare")
        guard case .connection(let configuration) = Cloudflare.preset.configuration else { return XCTFail() }
        XCTAssertNil(configuration.tokenRevocation)
        XCTAssertEqual(configuration.oauthClientField, "clientID")
        XCTAssertNil(configuration.oauthHostField, "Cloudflare's sign-in server is the same for every account")
        XCTAssertNil(configuration.oauthPathField)
        let oauth = try XCTUnwrap(configuration.oauth(for: cloudflare.settings))
        XCTAssertEqual(oauth.issuer.absoluteString, "https://dash.cloudflare.com")
        XCTAssertEqual(oauth.authorizationEndpoint.absoluteString, "https://dash.cloudflare.com/oauth2/auth")
        XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "https://dash.cloudflare.com/oauth2/token")
        XCTAssertEqual(oauth.revocationEndpoint?.absoluteString, "https://dash.cloudflare.com/oauth2/revoke")
        XCTAssertNil(oauth.deviceAuthorizationEndpoint, "an authorization code with PKCE, not a device code")
        XCTAssertFalse(oauth.usesResourceIndicator)
        XCTAssertEqual(oauth.authorizationParameters, ["prompt": "login"], "the member signs in afresh, never as whoever the browser is signed in as")
        XCTAssertTrue(oauth.scopes.allSatisfy { $0.hasSuffix(".read") || $0 == "offline_access" }, "Cloudflare Detection only reads")
        XCTAssertEqual(Set(oauth.scopes), ["account-settings.read", "teams.read", "account-analytics.read", "argotunnel.read", "zone.read", "dns.read",
                                           "analytics.read", "zone-settings.read", "zone-waf.read"])
        XCTAssertEqual(oauth.unlistedScopes, ["offline_access"])
        XCTAssertFalse(oauth.scopes.contains { $0.contains("token") }, "no scope reads API tokens, so no operation lists them")
        XCTAssertFalse(Cloudflare.operations.contains { type(of: $0).name == "api-tokens" })
        XCTAssertTrue(Cloudflare.setup.contains { $0.contains("com.pdparchitect.pion:/oauth2callback") }, "the setup names the redirect URI Pion uses")
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        ToolCatalog.use(PionCatalogue.entries)
        XCTAssertTrue(ToolConnectionService.signsInThroughBrowser(cloudflare))
        XCTAssertFalse(ToolConnectionService.signsInWithCode(cloudflare))
        XCTAssertEqual(ToolConnectionService.configuredRedirectURI(for: cloudflare, bundleIdentifier: "com.pdparchitect.pion")?.absoluteString,
                       "com.pdparchitect.pion:/oauth2callback")
        XCTAssertEqual(ToolConnectionService.configuredRedirectURI(for: cloudflare, bundleIdentifier: "com.pdparchitect.pion.local")?.absoluteString,
                       "com.pdparchitect.pion.local:/oauth2callback")
        XCTAssertNotNil(PionAdapters.all["cloudflare"])
        XCTAssertEqual(Cloudflare.adapter.watchedTool, "security-events")
        XCTAssertEqual(Cloudflare.radar.name, "Cloudflare Radar")
        XCTAssertEqual(Cloudflare.radar.id, "1a8b84b4-61cf-489c-9674-7dd239072a2e")
        let setup = Cloudflare.setup.joined(separator: "\n")
        XCTAssertTrue(Cloudflare.auditScopes.allSatisfy { setup.contains("`\($0)`") }, "the setup adds every scope asked for: \(setup)")
        let listed = try JSONSerialization.jsonObject(with: try await Cloudflare.adapter.tools(for: cloudflare)) as! [String: Any]
        for tool in try XCTUnwrap(listed["tools"] as? [[String: Any]]) {
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true, "\(tool["name"] ?? "")")
        }
    }

    /// Nothing goes anywhere but api.cloudflare.com, and an account ID Cloudflare would not give is refused before
    /// anything is sent.
    func testOnlyAPICloudflareComAndAWellFormedAccountAreReached() async throws {
        let service = FakeService()
        for base in ["https://api.cloudflare.com.evil.example/client/v4", "http://api.cloudflare.com/client/v4", "https://api.cloudflare.com:8443/client/v4", "https://api.cloudflare.com/client/v5"] {
            let client = ServiceClient(base: URL(string: base)!, access: service, settings: ["account": Self.accountID])
            do { _ = try await Cloudflare.Zones().run(.init(name: nil, limit: nil), on: client); XCTFail(base) }
            catch { XCTAssertTrue(error.localizedDescription.contains("Nothing was sent"), "\(base): \(error.localizedDescription)") }
        }
        let wrong = try Cloudflare.preset.makeConnection(name: "Cloudflare", values: ["account": "not-an-account", "clientID": Self.clientID])
        let refused = try await callTool(Cloudflare.adapter, "members", "{}", on: service, in: wrong)
        XCTAssertTrue(refused.isError && refused.text.contains("32 hexadecimal"), refused.text)
        XCTAssertTrue(service.requests.isEmpty)
    }

    /// A zone's DNS records are read page after page to the total Cloudflare gives, with the apex, MX and NS first.
    func testDNSRecordsFollowEveryPageWithTheApexMXAndNSFirst() async throws {
        let service = FakeService()
        Self.zone(service)
        let path = "/client/v4/zones/\(Self.zoneID)/dns_records"
        service.sequences[path] = [
            Self.page(#"{"id":"r1","type":"A","name":"app.kestrel.example","content":"203.0.113.7","proxied":true,"ttl":1,"modified_on":"2026-11-20T10:00:00Z"}"#, perPage: 500, total: 2, totalPages: 2),
            Self.page(#"{"id":"r2","type":"MX","name":"kestrel.example","content":"mx.evil.example","proxied":false,"ttl":300,"modified_on":"2026-11-23T10:00:00Z"}"#, page: 2, perPage: 500, total: 2, totalPages: 2),
        ]
        let records = try await call("zone-dns", #"{"zone":"kestrel.example"}"#, service)
        XCTAssertFalse(records.isError, records.text)
        let lines = records.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[1].hasPrefix("MX kestrel.example → mx.evil.example"), records.text)
        XCTAssertTrue(records.text.contains("A app.kestrel.example → 203.0.113.7 (proxied), TTL auto"), records.text)
        XCTAssertEqual(records.structured?["complete"] as? Bool, true)
        let zoneLookup = queryItems(service.requests.first)
        XCTAssertEqual(zoneLookup["name"], "kestrel.example")
        XCTAssertEqual(zoneLookup["account.id"], Self.accountID, "only this account's zone")
        XCTAssertEqual(service.requests.filter { $0.url?.path == path }.map { queryItems($0)["page"] }, ["1", "2"])
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "api.cloudflare.com" && $0.httpMethod == "GET" })
    }

    /// Every zone's security settings, weak zones first: one zone's settings come from the listing of them all, and
    /// another's, where that listing is gone, one by one; DNSSEC and the WAF's managed rules each from their own read.
    func testZoneSettingsLeadWithWeakSettingsAndReadEachSettingWhenTheListingIsGone() async throws {
        let other = "6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a"
        let service = FakeService()
        service.answers["/client/v4/zones"] = Self.page(#"{"id":"\#(other)","name":"shop.example","status":"active","plan":{"name":"Pro Website"},"type":"full"},{"id":"\#(Self.zoneID)","name":"kestrel.example","status":"active","plan":{"name":"Free Website"},"type":"full"}"#, total: 2, totalPages: 1)
        let weak = "/client/v4/zones/\(Self.zoneID)"
        service.answers["\(weak)/settings"] = (200, #"{"success":true,"errors":[],"result":[{"id":"ssl","value":"flexible"},{"id":"min_tls_version","value":"1.0"},{"id":"always_use_https","value":"off"},{"id":"automatic_https_rewrites","value":"on"},{"id":"security_header","value":{"strict_transport_security":{"enabled":false}}},{"id":"tls_1_3","value":"on"},{"id":"opportunistic_encryption","value":"on"},{"id":"security_level","value":"medium"},{"id":"browser_check","value":"off"},{"id":"ssl_automatic_mode","value":"custom"},{"id":"rocket_loader","value":"on"}]}"#)
        service.answers["\(weak)/dnssec"] = (200, #"{"success":true,"errors":[],"result":{"status":"disabled"}}"#)
        let strong = "/client/v4/zones/\(other)"
        for (id, value) in [("ssl", #""strict""#), ("min_tls_version", #""1.2""#), ("always_use_https", #""on""#), ("tls_1_3", #""zrt""#),
                            ("security_header", #"{"strict_transport_security":{"enabled":true,"max_age":31536000,"include_subdomains":true,"preload":false}}"#)] {
            service.answers["\(strong)/settings/\(id)"] = (200, #"{"success":true,"errors":[],"result":{"id":"\#(id)","value":\#(value),"editable":true}}"#)
        }
        service.answers["\(strong)/dnssec"] = (200, #"{"success":true,"errors":[],"result":{"status":"active","algorithm":"13"}}"#)
        service.answers["\(strong)/rulesets/phases/http_request_firewall_managed/entrypoint"] = (200, #"{"success":true,"errors":[],"result":{"id":"e1","phase":"http_request_firewall_managed","rules":[{"id":"r1","action":"execute","action_parameters":{"id":"efb7b8c949ac4650a09736fc376e9aee"},"enabled":true},{"id":"r2","action":"execute","action_parameters":{"id":"4814384a9e5d4991b9815dcfc25d2f1f"},"enabled":false}]}}"#)
        let result = try await call("zone-settings", "{}", service)
        XCTAssertFalse(result.isError, result.text)
        let lines = result.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "The security settings of 2 zones:")
        XCTAssertEqual(lines.dropFirst().first, "Weak settings in 1 of 2 zones:")
        let flagged = try XCTUnwrap(lines.first { $0.hasPrefix("⚠ kestrel.example: ") })
        for words in ["SSL/TLS Flexible", "minimum TLS 1.0", "HTTPS not enforced", "DNSSEC off"] { XCTAssertTrue(flagged.contains(words), "\(words): \(flagged)") }
        XCTAssertFalse(lines.contains { $0.hasPrefix("⚠ shop.example") }, result.text)
        let noted = try XCTUnwrap(lines.first { $0.hasPrefix("· kestrel.example: ") })
        XCTAssertTrue(noted.contains("HSTS off") && noted.contains("Browser Integrity Check off") && noted.contains("no WAF managed ruleset deployed at the zone"), noted)
        let shop = try XCTUnwrap(lines.first { $0.hasPrefix("shop.example [\(other)]") })
        for words in ["(active, plan Pro Website, full setup)", "SSL/TLS Full (strict)", "minimum TLS 1.2", "HSTS on (max-age 365 days, includeSubDomains)",
                      "TLS 1.3 on with 0-RTT", "DNSSEC active", "Opportunistic Encryption not given",
                      "WAF managed rules Cloudflare Managed Ruleset, Cloudflare OWASP Core Ruleset (off)"] {
            XCTAssertTrue(shop.contains(words), "\(words): \(shop)")
        }
        let order = lines.compactMap { line in ["kestrel.example [", "shop.example ["].first { line.hasPrefix($0) } }
        XCTAssertEqual(order, ["kestrel.example [", "shop.example ["], "weak zones first")
        let asked = Set(service.requests.compactMap { $0.url?.path })
        XCTAssertTrue(asked.contains("\(strong)/settings/ssl") && asked.contains("\(strong)/settings/browser_check"), "each setting read once the listing is gone")
        XCTAssertFalse(asked.contains("\(weak)/settings/ssl"), "a setting the listing gave is not read again")
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "api.cloudflare.com" })
        XCTAssertEqual(result.structured?["weakZones"] as? Int, 1)
        XCTAssertEqual(queryItems(service.requests.first)["account.id"], Self.accountID)

        // One zone by name; a sign-in without zone-waf.read still reads the rest, and says what it could not.
        let partial = FakeService()
        Self.zone(partial)
        partial.answers["\(weak)/settings"] = service.answers["\(weak)/settings"]
        partial.answers["\(weak)/dnssec"] = (200, #"{"success":true,"errors":[],"result":{"status":"pending"}}"#)
        partial.answers["\(weak)/rulesets/phases/http_request_firewall_managed/entrypoint"] = (403, #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#)
        let one = try await call("zone-settings", #"{"zone":"kestrel.example"}"#, partial)
        XCTAssertFalse(one.isError, one.text)
        XCTAssertTrue(one.text.hasPrefix("The security settings of kestrel.example:") && one.text.contains("DNSSEC pending"), one.text)
        XCTAssertTrue(one.text.contains("Not read for kestrel.example: WAF managed rules: the sign-in lacks the scope zone-waf.read"), one.text)
        XCTAssertEqual(one.structured?["complete"] as? Bool, false)

        // A sign-in without zone-settings.read reads no zone's settings, and is told the scope to add.
        let refused = FakeService()
        Self.zone(refused)
        refused.answers["\(weak)/settings"] = (403, #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#)
        let denied = try await call("zone-settings", #"{"zone":"kestrel.example"}"#, refused)
        XCTAssertTrue(denied.isError && denied.text.contains("the scope zone-settings.read"), denied.text)
        let unknown = try await call("zone-settings", #"{"zone":"nowhere.example"}"#, refused)
        XCTAssertTrue(unknown.isError && unknown.text.contains("no zone nowhere.example"), unknown.text)
    }

    /// A zone's records that point outside it, by provider, led by CNAMEs whose target doesn't resolve: possible
    /// takeover only at providers where others have claimed such names. Targets are looked up at Cloudflare's own
    /// DNS-over-HTTPS resolver, without the token, at most as many as asked, those at such providers first; only
    /// NXDOMAIN, or NOERROR with no address, is taken for not resolving, never SERVFAIL or no answer in time.
    func testDNSExposureGroupsOutsideTargetsByProviderAndLeadsWithThoseThatDoNotResolve() async throws {
        let service = FakeService()
        Self.zone(service)
        let records = [
            #"{"id":"r1","type":"CNAME","name":"old.kestrel.example","content":"kestrel-old.herokuapp.com","proxied":false}"#,
            #"{"id":"r2","type":"CNAME","name":"files.kestrel.example","content":"files-kestrel.s3.amazonaws.com","proxied":false}"#,
            #"{"id":"r3","type":"CNAME","name":"app.kestrel.example","content":"kestrel-app.azurewebsites.net","proxied":true}"#,
            #"{"id":"r4","type":"CNAME","name":"help.kestrel.example","content":"kestrel.zendesk.com","proxied":false}"#,
            #"{"id":"r5","type":"CNAME","name":"docs.kestrel.example","content":"kestrel.github.io","proxied":false}"#,
            #"{"id":"r6","type":"CNAME","name":"www.kestrel.example","content":"kestrel.example","proxied":true}"#,
            #"{"id":"r7","type":"CNAME","name":"legacy.kestrel.example","content":"gone.kestrel.example","proxied":false}"#,
            #"{"id":"r8","type":"CNAME","name":"blog.kestrel.example","content":"blog.partner.example","proxied":false}"#,
            #"{"id":"r9","type":"A","name":"intranet.kestrel.example","content":"10.1.2.3","proxied":false}"#,
            #"{"id":"r10","type":"A","name":"kestrel.example","content":"185.199.108.153","proxied":false}"#,
            #"{"id":"r11","type":"A","name":"api.kestrel.example","content":"203.0.113.7","proxied":true}"#,
            #"{"id":"r12","type":"NS","name":"dev.kestrel.example","content":"ns-123.awsdns-45.com","proxied":false}"#,
            #"{"id":"r13","type":"MX","name":"kestrel.example","content":"mx.kestrel.example","proxied":false}"#,
        ]
        let path = "/client/v4/zones/\(Self.zoneID)/dns_records"
        service.answers[path] = Self.page(records.joined(separator: ","), perPage: 500, total: records.count, totalPages: 1)

        /// Cloudflare's resolver as a stand-in: its JSON answers by name and type, and no answer in time for some names.
        final class Resolver: ServiceAccess, @unchecked Sendable {
            let answers = FakeService()
            var slow: Set<String> = []
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? ""
                if slow.contains(name) {
                    answers.lock.withLock { answers.requests.append(request) }
                    throw URLError(.timedOut)
                }
                return try await answers.data(for: request)
            }
            func asked() -> [String] { answers.lock.withLock { answers.requests.compactMap { $0.url?.query } } }
        }
        let resolver = Resolver()
        func doh(_ name: String, _ type: String, _ body: String) { resolver.answers.answers["/dns-query?name=\(name)&type=\(type)"] = (200, body) }
        doh("kestrel-old.herokuapp.com", "A", #"{"Status":3,"TC":false,"Question":[{"name":"kestrel-old.herokuapp.com","type":1}]}"#)
        doh("files-kestrel.s3.amazonaws.com", "A", #"{"Status":0,"Answer":[{"name":"files-kestrel.s3.amazonaws.com","type":5,"TTL":300,"data":"s3-w.amazonaws.com."},{"name":"s3-w.amazonaws.com","type":1,"TTL":5,"data":"52.0.0.1"}]}"#)
        doh("kestrel-app.azurewebsites.net", "A", #"{"Status":3,"Answer":[{"name":"kestrel-app.azurewebsites.net","type":5,"TTL":300,"data":"waws-prod-xyz.cloudapp.net."}]}"#)
        doh("kestrel.zendesk.com", "A", #"{"Status":0}"#)
        doh("kestrel.zendesk.com", "AAAA", #"{"Status":0,"Answer":[]}"#)
        doh("blog.partner.example", "A", #"{"Status":2}"#)
        resolver.slow = ["kestrel.github.io"]
        func exposure(_ arguments: String) async throws -> AdapterResult {
            resolver.answers.lock.withLock { resolver.answers.requests = [] }
            return try await Cloudflare.$resolver.withValue(resolver) { try await call("dns-exposure", arguments, service) }
        }
        let result = try await exposure(#"{"zone":"kestrel.example"}"#)
        XCTAssertFalse(result.isError, result.text)
        let text = result.text
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("kestrel.example: 13 DNS records read; 7 records point outside the zone"), lines[0])
        XCTAssertEqual(lines[1], "Target doesn't resolve — possible takeover (2):")
        XCTAssertTrue(lines[2].contains("app.kestrel.example → kestrel-app.azurewebsites.net (proxied) [doesn't resolve: NXDOMAIN at waws-prod-xyz.cloudapp.net] — target doesn't resolve — possible takeover"), lines[2])
        XCTAssertTrue(lines[3].contains("old.kestrel.example → kestrel-old.herokuapp.com [doesn't resolve: NXDOMAIN]") && lines[3].contains("at Heroku"), lines[3])
        XCTAssertTrue(text.contains("Target doesn't resolve — check whether still in use (1):\n  CNAME help.kestrel.example → kestrel.zendesk.com [doesn't resolve: no address (NOERROR, no answer)]"), text)
        XCTAssertTrue(text.contains("Points at a name in this zone that no record answers (1):\n  CNAME legacy.kestrel.example → gone.kestrel.example"), text)
        XCTAssertTrue(text.contains("Private or reserved addresses published in public DNS (1):\n  A intranet.kestrel.example → 10.1.2.3"), text)
        XCTAssertFalse(text.contains("www.kestrel.example"), "a name in the zone that a record answers is the zone's own")
        XCTAssertTrue(text.contains("AWS S3 (names left pointing at its deleted resources have been claimed by others):"), text)
        XCTAssertTrue(text.contains("files.kestrel.example → files-kestrel.s3.amazonaws.com [resolves via s3-w.amazonaws.com] — check whether still in use; at AWS S3 a target still resolves after its resource is deleted"), text)
        XCTAssertTrue(text.contains("GitHub Pages (names left pointing at its deleted resources have been claimed by others in some cases):"), text)
        XCTAssertTrue(text.contains("A kestrel.example → 185.199.108.153") && text.contains("docs.kestrel.example → kestrel.github.io [couldn't tell: "), text)
        XCTAssertTrue(text.contains("Other hosts outside the zone:\n  CNAME blog.kestrel.example → blog.partner.example [couldn't tell: the resolver answered SERVFAIL]"), text)
        XCTAssertTrue(text.contains("Subdomains delegated to other name servers (1):\n  NS dev.kestrel.example → ns-123.awsdns-45.com — delegated: check the zone still exists at Amazon Route 53"), text)
        XCTAssertTrue(text.contains("1 address Pion does not recognise, in 1 record") && text.contains("A api.kestrel.example → 203.0.113.7 (proxied)"), text)
        XCTAssertTrue(text.contains("Looked up 6 of 6 distinct targets through Cloudflare's DNS-over-HTTPS resolver."), text)
        XCTAssertFalse(text.lowercased().contains("can be taken over") || text.lowercased().contains("exploitable"), text)
        XCTAssertEqual((result.structured?["possibleTakeover"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((result.structured?["notResolving"] as? [[String: Any]])?.count, 1, "SERVFAIL and no answer in time are never taken for not resolving")
        XCTAssertEqual(result.structured?["complete"] as? Bool, true)
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "api.cloudflare.com" })
        // Each target asked for its addresses, AAAA only where A gave none, as JSON, of Cloudflare's resolver, without the token.
        let sent = resolver.answers.lock.withLock { resolver.answers.requests }
        XCTAssertTrue(sent.allSatisfy { $0.url?.host == "cloudflare-dns.com" && $0.url?.path == "/dns-query" && $0.httpMethod == "GET"
                && $0.value(forHTTPHeaderField: "Accept") == "application/dns-json" && $0.value(forHTTPHeaderField: "Authorization") == nil }, "\(sent)")
        XCTAssertEqual(Set(resolver.asked()), ["name=kestrel-old.herokuapp.com&type=A", "name=files-kestrel.s3.amazonaws.com&type=A", "name=kestrel-app.azurewebsites.net&type=A",
                                               "name=kestrel.zendesk.com&type=A", "name=kestrel.zendesk.com&type=AAAA", "name=kestrel.github.io&type=A",
                                               "name=blog.partner.example&type=A"])

        // At most as many lookups as asked, those at providers where others have claimed such names first.
        let capped = try await exposure(#"{"zone":"kestrel.example","lookups":2}"#)
        XCTAssertTrue(capped.text.contains("Looked up 2 of 6 distinct targets through Cloudflare's DNS-over-HTTPS resolver; 4 were not, as at most 2 are"), capped.text)
        XCTAssertEqual(Set(resolver.asked()), ["name=files-kestrel.s3.amazonaws.com&type=A", "name=kestrel-app.azurewebsites.net&type=A"])
        XCTAssertTrue(capped.text.contains("kestrel-old.herokuapp.com [not looked up]"), capped.text)

        // A listing cut short says so, and does not say which names in the zone no record answers; 0 looks none up.
        let cut = FakeService()
        Self.zone(cut)
        cut.sequences[path] = [Self.page(records.prefix(7).joined(separator: ","), perPage: 500, total: 600, totalPages: 2), (500, #"{"success":false,"errors":[{"code":10000,"message":"internal error"}]}"#)]
        resolver.answers.lock.withLock { resolver.answers.requests = [] }
        let incomplete = try await Cloudflare.$resolver.withValue(resolver) { try await call("dns-exposure", #"{"zone":"kestrel.example","lookups":0}"#, cut) }
        XCTAssertTrue(incomplete.text.contains("Incomplete: stopped at page 2") && !incomplete.text.contains("legacy.kestrel.example"), incomplete.text)
        XCTAssertTrue(incomplete.text.contains("No target was looked up, as lookups is 0"), incomplete.text)
        XCTAssertTrue(resolver.asked().isEmpty)
    }

    /// The resolver's access carries no credentials and reaches only Cloudflare's resolver, refusing any other host
    /// before anything is sent.
    func testTheResolverIsReachedWithoutCredentialsAndNothingElse() async throws {
        let access = ToolConnectionAccess.anonymous(URL(string: "https://cloudflare-dns.com")!, timeout: 1)
        for address in ["https://api.cloudflare.com/client/v4/zones", "http://cloudflare-dns.com/dns-query", "https://cloudflare-dns.com.evil.example/dns-query"] {
            do { _ = try await access.data(for: URLRequest(url: URL(string: address)!)); XCTFail(address) }
            catch { XCTAssertTrue(error.localizedDescription.contains("may only reach its own service"), "\(address): \(error.localizedDescription)") }
        }
    }

    /// The provider a target belongs to, by the longest end of its name, S3 by the bucket's region in the middle; and
    /// which addresses are not the Internet's.
    func testProvidersAreKnownByTheirNamesAndInternalAddressesByTheirRanges() {
        XCTAssertEqual(Cloudflare.provider(of: "a.s3-website-eu-west-1.amazonaws.com")?.name, "AWS S3")
        XCTAssertEqual(Cloudflare.provider(of: "bucket.s3.eu-west-2.amazonaws.com")?.name, "AWS S3")
        XCTAssertEqual(Cloudflare.provider(of: "x.eu-west-1.elb.amazonaws.com")?.name, "AWS load balancer")
        XCTAssertEqual(Cloudflare.provider(of: "d111.cloudfront.net")?.takeover, Cloudflare.Provider.Takeover.none)
        XCTAssertEqual(Cloudflare.provider(of: "kestrel.trafficmanager.net")?.name, "Microsoft Azure")
        XCTAssertEqual(Cloudflare.provider(of: "landing.ck.page")?.name, "Kit (ConvertKit)")
        XCTAssertNil(Cloudflare.provider(of: "notgithub.io"))
        for address in ["10.0.0.1", "172.20.1.1", "192.168.1.1", "127.0.0.1", "169.254.1.1", "100.64.0.1", "fd00::1", "fe80::1", "::1"] {
            XCTAssertTrue(Cloudflare.isInternal(address), address)
        }
        for address in ["203.0.113.7", "172.32.0.1", "100.128.0.1", "2606:4700::1"] { XCTAssertFalse(Cloudflare.isInternal(address), address) }
    }

    /// Cloudflare's envelope is read strictly: no success, success false, or any error, with a message or without, is
    /// an error and never an empty result; a result left out is unreadable.
    func testErrorsAndMissingResultsAreNeverEmpty() async throws {
        let cases: [(String, String)] = [
            (#"{"success":false,"errors":[],"result":[]}"#, "did not succeed"),
            (#"{"success":true,"errors":[{"code":10001}],"result":[]}"#, "error 10001 without a message"),
            (#"{"success":true,"errors":[{}],"result":[]}"#, "an error without a message or code"),
            (#"{"success":true,"errors":[{"code":7003,"message":"No route for the URI"}],"result":[]}"#, "No route for the URI (code 7003)"),
            (#"{"success":true,"errors":[]}"#, "could not be read"),
            (#"{"errors":[],"result":[]}"#, "could not be read"),
            (#"{"success":true,"errors":[],"result":[{"email":"no id"}]}"#, "could not be read"),
            (#"{"success":true,"errors":[],"result":[],"result_info":{"total_count":"many"}}"#, "could not be read"),
            (#"{"success":true,"errors":[],"result":[],"result_info":{"cursor":42}}"#, "could not be read"),
        ]
        for (body, said) in cases {
            let service = FakeService()
            service.answers["\(account)/members"] = (200, body)
            let result = try await call("members", "{}", service)
            XCTAssertTrue(result.isError && result.text.contains(said), "\(body): \(result.text)")
            XCTAssertFalse(result.text.contains("no members"), body)
        }
    }

    /// Paging that contradicts itself is never taken as whole: a count other than the page holds, a total of none with
    /// items, another page than asked for, a total the pages never reach, an empty page that says more follow, and a
    /// cursor given twice or with a total of none.
    func testContradictoryPagingIsNeverTakenAsWhole() async throws {
        let one = #"{"id":"m1","status":"accepted","user":{"email":"a@kestrel.example"},"roles":[{"name":"Administrator"}]}"#
        let cases: [([(Int, String)], String)] = [
            ([Self.page(one, count: 3)], "counted 3 on a page that held 1"),
            ([Self.page(one, total: 0)], "counted none"),
            ([Self.page(one, page: 2)], "page 2 when asked for page 1"),
            ([Self.page(one, total: 5, totalPages: 1)], "said 5 match but its pages ended after 1"),
            ([Self.page(one, perPage: 50, total: 3, totalPages: 3), Self.page("", page: 2, total: 3, totalPages: 3)], "empty page that said more follow"),
            ([Self.page(one, total: 1), ], ""),
        ]
        for (pages, said) in cases {
            let service = FakeService()
            service.sequences["\(account)/members"] = pages
            let result = try await call("members", "{}", service)
            if said.isEmpty { XCTAssertFalse(result.isError, result.text); continue }
            XCTAssertTrue(result.text.contains(said), "\(said): \(result.text)")
            XCTAssertTrue(result.isError || result.text.contains("Incomplete"), result.text)
            XCTAssertNotEqual(result.structured?["complete"] as? Bool, true, said)
        }
        let registration = #"{"id":"6f9d2a3c-1b2e-4f5a-8c7d-0e1f2a3b4c5d","device":{"id":"d1","name":"LT-1"},"user":{"email":"a@kestrel.example"},"revoked_at":null}"#
        for (info, said) in [(#""cursor":"next","total_count":0"#, "counted none"), (#""cursor":"same""#, "same next page again")] {
            let service = FakeService()
            service.answers["\(account)/devices/registrations"] = (200, #"{"success":true,"errors":[],"result":[\#(registration)],"result_info":{\#(info),"count":1,"per_page":500}}"#)
            let result = try await call("devices", "{}", service)
            XCTAssertTrue(result.text.contains(said) || result.isError, "\(said): \(result.text)")
            XCTAssertNotEqual(result.structured?["complete"] as? Bool, true, said)
        }
    }

    /// A page after the first that fails keeps what earlier pages held and says where and why it stopped.
    func testAFailedPageSaysWhereItStopped() async throws {
        let service = FakeService()
        service.sequences["\(account)/members"] = [
            Self.page(#"{"id":"m1","user":{"email":"a@kestrel.example","two_factor_authentication_enabled":true},"roles":[{"name":"Analytics"}]}"#, total: 2, totalPages: 2),
            (500, #"{"success":false,"errors":[{"code":10000,"message":"internal error"}]}"#),
        ]
        let result = try await call("members", "{}", service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("a@kestrel.example") && result.text.contains("Incomplete: stopped at page 2 reading members because") && result.text.contains("internal error"), result.text)
        XCTAssertEqual(result.structured?["complete"] as? Bool, false)
    }

    /// The rate limit is waited out once when Cloudflare says it is soon, and said otherwise; a refusal names the scope
    /// to add and the role it may be instead; a sign-in Cloudflare no longer accepts asks for the tool to be connected again.
    func testRateLimitIsWaitedOutAndRefusalsNameTheScope() async throws {
        let soon = FakeService()
        soon.sequences["\(account)/members"] = [(429, #"{"success":false,"errors":[{"code":971,"message":"Please wait"}]}"#), Self.page(#"{"id":"m1","roles":[]}"#, total: 1)]
        soon.sequenceHeaders["\(account)/members"] = [["Retry-After": "5"], [:]]
        let waited = Mutex<[Double]>([])
        let result = try await Cloudflare.$pause.withValue({ seconds in waited.withLock { $0.append(seconds) } }) {
            try await callTool(Cloudflare.adapter, "members", "{}", on: soon, in: cloudflare)
        }
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(waited.withLock { $0 }, [5])
        let later = FakeService()
        later.answers["\(account)/members"] = (429, #"{"success":false,"errors":[{"code":971,"message":"Please wait"}]}"#)
        later.responseHeaders = ["Retry-After": "300"]
        let limited = try await call("members", "{}", later)
        XCTAssertTrue(limited.isError && limited.text.contains("asked to wait 300 seconds"), limited.text)
        let forbidden = FakeService()
        forbidden.answers["\(account)/access/apps"] = (403, #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#)
        let refused = try await call("access-apps", "{}", forbidden)
        XCTAssertTrue(refused.isError && refused.text.contains("lacks the scope teams.read") && refused.text.contains("member's role")
                      && refused.text.contains("OAuth clients") && refused.text.contains("Authentication error"), refused.text)
        let malformed = FakeService()
        malformed.answers["\(account)/members"] = (400, #"{"success":false,"errors":[{"code":6003,"message":"Invalid request headers"}]}"#)
        let rejected = try await call("members", "{}", malformed)
        XCTAssertTrue(rejected.isError && rejected.text.contains("did not accept the sign-in") && rejected.text.contains("Connect the tool again in Settings › Tools")
                      && !rejected.text.contains("API token"), rejected.text)
    }

    /// Firewall events ask for one more than kept, so a result says when more matched; GraphQL errors, with a message or
    /// without, and an answer without the zone are errors.
    func testFirewallEventsSayWhenMoreMatchedAndErrorsAreNeverEmpty() async throws {
        let service = FakeService()
        Self.zone(service)
        let event = #"{"datetime":"2026-11-24T09:00:00Z","action":"block","clientIP":"203.0.113.77","clientCountryName":"NG","clientAsn":"64500","clientRequestHTTPHost":"kestrel.example","clientRequestPath":"/login","source":"waf","ruleId":"abc","rayName":"8f00"}"#
        service.answers["/client/v4/graphql"] = (200, #"{"data":{"viewer":{"zones":[{"firewallEventsAdaptive":[\#(event),\#(event),\#(event)]}]}},"errors":null}"#)
        let events = try await call("firewall-events", #"{"zone":"kestrel.example","ip":"203.0.113.77","limit":2}"#, service)
        XCTAssertFalse(events.isError, events.text)
        XCTAssertTrue(events.text.contains("2 events") && events.text.contains("block 203.0.113.77 (NG, AS64500)") && events.text.contains("More events match than the 2 kept"), events.text)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: service.requests.last?.httpBody ?? Data()) as? [String: Any])
        let variables = try XCTUnwrap(body["variables"] as? [String: Any])
        XCTAssertEqual(variables["zoneTag"] as? String, Self.zoneID)
        XCTAssertEqual(variables["limit"] as? Int, 3, "one more than kept")
        XCTAssertEqual((variables["filter"] as? [String: String])?["clientIP"], "203.0.113.77")
        for answer in [#"{"data":null,"errors":[{"message":"zone does not have access to the path"}]}"#, #"{"data":{"viewer":{"zones":[]}},"errors":[{}]}"#,
                       #"{"data":{"viewer":{"zones":[]}}}"#, #"{"data":{"viewer":{"zones":[{"firewallEventsAdaptive":null}]}}}"#] {
            let failing = FakeService()
            Self.zone(failing)
            failing.answers["/client/v4/graphql"] = (200, answer)
            let result = try await call("firewall-events", #"{"zone":"kestrel.example"}"#, failing)
            XCTAssertTrue(result.isError, "\(answer): \(result.text)")
        }
    }

    func testTheAuditLogAndMembers() async throws {
        let service = FakeService()
        service.answers["\(account)/audit_logs"] = (200, #"{"success":true,"errors":[],"result":[{"id":"0b7d4a7c-1c3d-4e5f-8a9b-0c1d2e3f4a5b","when":"2026-11-24T08:00:00Z","action":{"type":"rec_add","result":true},"actor":{"email":"ops@kestrel.example","ip":"198.51.100.4","type":"user"},"interface":"API","resource":{"type":"DNS_record","id":"r1"},"metadata":{"zone_name":"kestrel.example","name":"kestrel.example","type":"MX"}}]}"#)
        let log = try await call("audit-log", #"{"since":"2026-11-23T00:00:00Z","actor":"ops@kestrel.example","zone":"kestrel.example"}"#, service)
        XCTAssertFalse(log.isError, log.text)
        XCTAssertTrue(log.text.contains("rec_add by ops@kestrel.example from 198.51.100.4 via API on DNS_record r1 (kestrel.example, kestrel.example, MX)"), log.text)
        let sent = queryItems(service.requests.first)
        XCTAssertEqual(sent["since"], "2026-11-23T00:00:00Z")
        XCTAssertNotNil(sent["before"])
        XCTAssertEqual(sent["actor.email"], "ops@kestrel.example")
        XCTAssertEqual(sent["zone.name"], "kestrel.example")
        XCTAssertEqual(sent["direction"], "desc")

        let members = FakeService()
        members.sequences["\(account)/members"] = [
            Self.page(#"{"id":"m1","status":"accepted","user":{"email":"dev@kestrel.example","two_factor_authentication_enabled":true},"roles":[{"id":"r2","name":"Analytics"}]}"#, total: 2, totalPages: 2),
            Self.page(#"{"id":"m2","status":"accepted","user":{"email":"ops@kestrel.example","two_factor_authentication_enabled":false},"roles":[{"id":"r1","name":"Super Administrator - All Privileges"}]}"#, page: 2, total: 2, totalPages: 2),
        ]
        let people = try await call("members", "{}", members)
        let lines = people.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("ops@kestrel.example") && lines[0].contains("Super Administrator") && lines[0].contains("no 2FA"), people.text)
        XCTAssertEqual(members.requests.map { queryItems($0)["page"] }, ["1", "2"])
    }

    /// Access logins are read by time, as Cloudflare gives no paging: each next request asks up to a second after the
    /// oldest, logins read twice count once, and the read is whole only once a request brings nothing new.
    func testAccessLoginsAreReadByTimeUntilNothingNew() async throws {
        let service = FakeService()
        let path = "\(account)/access/logs/access_requests"
        let hour = floor(Date().timeIntervalSince1970 / 3_600) * 3_600
        func at(_ hoursAgo: Double) -> String { Entra.iso(Date(timeIntervalSince1970: hour - hoursAgo * 3_600)) }
        let (since, until) = (at(10), at(0))
        func login(_ time: String, _ email: String, allowed: Bool, ray: String) -> String {
            #"{"user_email":"\#(email)","ip_address":"203.0.113.9","app_domain":"wiki.kestrel.example","app_uid":"a1","action":"login","allowed":\#(allowed),"created_at":"\#(time)","ray_id":"\#(ray)","connection":"okta","country_code":"NG"}"#
        }
        service.sequences[path] = [
            (200, #"{"success":true,"errors":[],"result":[\#(login(at(1), "eve@kestrel.example", allowed: false, ray: "r3")),\#(login(at(2), "bob@kestrel.example", allowed: true, ray: "r2")),\#(login(at(3), "eve@kestrel.example", allowed: false, ray: "r1"))]}"#),
            (200, #"{"success":true,"errors":[],"result":[\#(login(at(3), "eve@kestrel.example", allowed: false, ray: "r1"))]}"#),
        ]
        let blocked = try await call("access-logs", #"{"blocked":true,"since":"\#(since)","until":"\#(until)"}"#, service)
        XCTAssertFalse(blocked.isError, blocked.text)
        XCTAssertTrue(blocked.text.contains("2 logins") && blocked.text.contains("2 blocked") && blocked.text.contains("BLOCKED: eve@kestrel.example to wiki.kestrel.example from 203.0.113.9 (NG)"), blocked.text)
        XCTAssertFalse(blocked.text.contains("bob@"), blocked.text)
        XCTAssertEqual(blocked.structured?["complete"] as? Bool, true)
        let asked = service.requests.map(queryItems)
        guard asked.count == 2 else { return XCTFail("\(asked)") }
        XCTAssertEqual(asked[0]["until"], until)
        XCTAssertEqual(asked[1]["until"], Entra.iso(Date(timeIntervalSince1970: hour - 3 * 3_600 + 1)), "a second after the oldest")
        XCTAssertEqual(asked[1]["since"], since)

        let stuck = FakeService()
        let full = (0..<500).map { login(at(1), "eve@kestrel.example", allowed: false, ray: "s\($0)") }.joined(separator: ",")
        stuck.answers[path] = (200, #"{"success":true,"errors":[],"result":[\#(full)]}"#)
        let tied = try await call("access-logs", #"{"blocked":true,"since":"\#(since)","until":"\#(until)"}"#, stuck)
        XCTAssertTrue(tied.text.contains("more logins at \(at(1)) than Cloudflare gives at once"), tied.text)
        XCTAssertEqual(tied.structured?["complete"] as? Bool, false)
        let unreadable = FakeService()
        unreadable.answers[path] = (200, #"{"success":true,"errors":[],"result":[{"user_email":"a@b.example"}]}"#)
        let missing = try await call("access-logs", "{}", unreadable)
        XCTAssertTrue(missing.isError, "a login without a time is unreadable: \(missing.text)")
    }

    /// An application's policies in the order Access evaluates them; an application Cloudflare does not answer for by
    /// its ID is absent only when the whole list of applications does not name it.
    func testAnAccessAppWithItsPoliciesInOrder() async throws {
        let app = "6f9d2a3c-1b2e-4f5a-8c7d-0e1f2a3b4c5d"
        let service = FakeService()
        service.answers["\(account)/access/apps/\(app)"] = (200, #"{"success":true,"errors":[],"result":{"id":"\#(app)","name":"Wiki","type":"self_hosted","domain":"wiki.kestrel.example","session_duration":"24h"}}"#)
        service.answers["\(account)/access/apps/\(app)/policies"] = Self.page(#"{"id":"11111111-1111-4111-8111-111111111111","name":"Staff","decision":"allow","precedence":1,"include":[{"email_domain":{"domain":"kestrel.example"}}]},{"id":"22222222-2222-4222-8222-222222222222","name":"Health","decision":"bypass","precedence":2,"include":[{"everyone":{}}]}"#, total: 2, totalPages: 1)
        let read = try await call("access-app", #"{"id":"\#(app)"}"#, service)
        XCTAssertFalse(read.isError, read.text)
        let lines = read.text.split(separator: "\n").map(String.init)
        let bypass = try XCTUnwrap(lines.firstIndex { $0.contains("BYPASS Health") }), allow = try XCTUnwrap(lines.firstIndex { $0.contains("ALLOW Staff") })
        XCTAssertLessThan(bypass, allow, "bypass is evaluated first")
        XCTAssertTrue(read.text.contains("include email_domain kestrel.example") && read.text.contains("include everyone"), read.text)

        let gone = FakeService()
        gone.answers["\(account)/access/apps/\(app)"] = (404, #"{"success":false,"errors":[{"code":7003,"message":"No route for the URI"}]}"#)
        gone.answers["\(account)/access/apps"] = Self.page(#"{"id":"33333333-3333-4333-8333-333333333333","name":"Other"}"#, total: 1, totalPages: 1)
        let absent = try await call("access-app", #"{"id":"\#(app)"}"#, gone)
        XCTAssertTrue(!absent.isError && absent.text.contains("has no Access application") && absent.structured?["found"] as? Bool == false, absent.text)
        let unsure = FakeService()
        unsure.answers["\(account)/access/apps/\(app)"] = (404, #"{"success":false,"errors":[{"code":7003,"message":"No route for the URI"}]}"#)
        unsure.answers["\(account)/access/apps"] = Self.page(#"{"id":"33333333-3333-4333-8333-333333333333","name":"Other"}"#, total: 7, totalPages: 1)
        let inconclusive = try await call("access-app", #"{"id":"\#(app)"}"#, unsure)
        XCTAssertTrue(inconclusive.isError && inconclusive.text.contains("could not be read"), "a 404 and a list cut short show nothing: \(inconclusive.text)")
    }

    func testAnAccessUserWithSessionsAndPosture() async throws {
        let user = "44444444-4444-4444-8444-444444444444"
        let service = FakeService()
        service.answers["\(account)/access/users"] = Self.page(#"{"id":"\#(user)","email":"eve@kestrel.example","name":"Eve","last_successful_login":"2026-11-24T08:00:00Z","active_device_count":2,"access_seat":true}"#, total: 1)
        service.answers["\(account)/access/users/\(user)/active_sessions"] = (200, #"{"success":true,"errors":[],"result":[{"name":"nonce123","expiration":1795000000,"metadata":{"apps":{"a1":{"hostname":"wiki.kestrel.example","name":"Wiki"}},"iat":1794900000}}],"result_info":{"page":1,"per_page":100,"count":1,"total_count":1}}"#)
        service.answers["\(account)/access/users/\(user)/last_seen_identity"] = (200, #"{"success":true,"errors":[],"result":{"email":"eve@kestrel.example","ip":"203.0.113.9","geo":{"country":"NG"},"idp":{"type":"okta"},"device_id":"d1","is_warp":true,"devicePosture":{"p1":{"rule_name":"Disk encryption","success":false,"timestamp":"2026-11-24T07:00:00Z"}}}}"#)
        let read = try await call("access-user", #"{"user":"Eve@Kestrel.example"}"#, service)
        XCTAssertFalse(read.isError, read.text)
        XCTAssertTrue(read.text.contains("1 active Access session") && read.text.contains("wiki.kestrel.example"), read.text)
        XCTAssertTrue(read.text.contains("from 203.0.113.9 (NG)") && read.text.contains("Disk encryption: FAILED"), read.text)
        XCTAssertEqual(queryItems(service.requests.first)["email"], "eve@kestrel.example")
        let twice = FakeService()
        twice.answers["\(account)/access/users"] = Self.page(#"{"id":"\#(user)","email":"eve@kestrel.example"},{"id":"55555555-5555-4555-8555-555555555555","email":"eve@kestrel.example"}"#, total: 2)
        let ambiguous = try await call("access-user", #"{"user":"eve@kestrel.example"}"#, twice)
        XCTAssertTrue(ambiguous.isError && ambiguous.text.contains("2 users"), ambiguous.text)
    }

    func testGatewayActivityRulesListsDevicesAndTunnels() async throws {
        let service = FakeService()
        service.answers["/client/v4/graphql"] = (200, #"{"data":{"viewer":{"accounts":[{"gatewayResolverQueriesAdaptiveGroups":[{"count":42,"dimensions":{"queryNameReversed":"example.evil.c2","resolverDecision":"9"}}]}]}},"errors":null}"#)
        let activity = try await call("gateway-activity", "{}", service)
        XCTAssertTrue(!activity.isError && activity.text.contains("42 × c2.evil.example: resolver decision 9") && activity.text.contains("estimates"), activity.text)
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: service.requests.last?.httpBody ?? Data()) as? [String: Any])?["variables"] as? [String: Any])?["accountTag"] as? String, Self.accountID)

        service.answers["\(account)/gateway/rules"] = (200, #"{"success":true,"errors":[],"result":[{"id":"66666666-6666-4666-8666-666666666666","name":"Block malware","action":"block","enabled":false,"filters":["dns"],"traffic":"any(dns.content_category[*] in {80})","precedence":2},{"id":"77777777-7777-4777-8777-777777777777","name":"Allow all","action":"allow","enabled":true,"filters":["dns"],"precedence":1}],"result_info":{"count":2,"total_count":2}}"#)
        let rules = try await call("gateway-rules", "{}", service)
        XCTAssertTrue(rules.text.contains("2 rules, 1 turned off") && rules.text.contains("Block malware: block on dns, TURNED OFF"), rules.text)
        XCTAssertLessThan(try XCTUnwrap(rules.text.range(of: "Allow all")).lowerBound, try XCTUnwrap(rules.text.range(of: "Block malware")).lowerBound)
        service.answers["\(account)/gateway/rules"] = (200, #"{"success":true,"errors":[],"result":[{"id":"66666666-6666-4666-8666-666666666666","name":"x","action":"block"}],"result_info":{"count":1,"total_count":4}}"#)
        let partial = try await call("gateway-rules", "{}", service)
        XCTAssertTrue(partial.text.contains("said 4 match but gave 1"), partial.text)

        service.answers["\(account)/devices/registrations"] = (200, #"{"success":true,"errors":[],"result":[{"id":"88888888-8888-4888-8888-888888888888","device":{"id":"d1","name":"LT-0423","client_version":"2026.11"},"user":{"email":"eve@kestrel.example"},"revoked_at":"2026-11-24T08:30:00Z","last_seen_at":"2026-11-24T08:00:00Z","registration_type":"warp"}],"result_info":{"count":1,"per_page":500,"cursor":"","total_count":1}}"#)
        let devices = try await call("devices", "{}", service)
        XCTAssertTrue(devices.text.contains("LT-0423") && devices.text.contains("REVOKED 2026-11-24T08:30:00Z") && devices.text.contains("no posture results per device"), devices.text)
        XCTAssertEqual(queryItems(service.requests.last)["status"], "all")

        service.answers["\(account)/cfd_tunnel"] = Self.page(#"{"id":"99999999-9999-4999-8999-999999999999","name":"backdoor","status":"healthy","created_at":"2026-11-24T03:00:00Z","conns_active_at":"2026-11-24T03:01:00Z","tun_type":"cfd_tunnel","connections":[{"origin_ip":"10.0.0.5","colo_name":"LHR"}]}"#, perPage: 500, total: 1)
        let tunnels = try await call("tunnels", "{}", service)
        XCTAssertTrue(tunnels.text.contains("backdoor (cfd_tunnel): healthy") && tunnels.text.contains("origins 10.0.0.5"), tunnels.text)
        XCTAssertEqual(queryItems(service.requests.last)["is_deleted"], "false")
    }

    /// check-access tries each read once, says which parts the sign-in reaches and which scopes it holds, and sends
    /// nothing but reads; it asks Cloudflare to verify no token, as an OAuth sign-in has no such check.
    func testCheckAccessSaysWhichPartsTheSignInReachesAndItsScopes() async throws {
        let service = FakeService()
        Self.zone(service)
        service.answers["/client/v4/zones/\(Self.zoneID)/dns_records"] = Self.page("", total: 0)
        service.answers["/client/v4/zones/\(Self.zoneID)/settings/ssl"] = (200, #"{"success":true,"errors":[],"result":{"id":"ssl","value":"strict"}}"#)
        service.answers["/client/v4/zones/\(Self.zoneID)/dnssec"] = (200, #"{"success":true,"errors":[],"result":{"status":"active"}}"#)
        service.sequences["/client/v4/graphql"] = [(200, #"{"data":{"viewer":{}},"errors":null}"#), (200, #"{"data":null,"errors":[{"message":"Zero Trust is not enabled for this account"}]}"#)]
        service.answers["\(account)/audit_logs"] = (200, #"{"success":true,"errors":[],"result":[]}"#)
        service.answers["\(account)/members"] = Self.page("", total: 0)
        for path in ["access/logs/access_requests", "access/apps", "access/users", "gateway/rules", "devices/registrations", "cfd_tunnel"] {
            service.answers["\(account)/\(path)"] = (403, #"{"success":false,"errors":[{"code":9999,"message":"Zero Trust is not enabled for this account"}]}"#)
        }
        let checked = try await call("check-access", "{}", service)
        XCTAssertFalse(checked.isError, checked.text)
        XCTAssertTrue(checked.text.contains("✓ Zones (zone.read)") && checked.text.contains("✓ DNS records (dns.read)"), checked.text)
        XCTAssertTrue(checked.text.contains("✓ Zone settings (zone-settings.read)") && checked.text.contains("✓ DNSSEC (dns.read)"), checked.text)
        XCTAssertTrue(checked.text.contains("✓ WAF managed rules (zone-waf.read)"), "a zone without managed rules answers 404, which the sign-in may ask: \(checked.text)")
        XCTAssertTrue(checked.text.contains("✓ The account audit log (account-settings.read)") && checked.text.contains("✓ Members"), checked.text)
        XCTAssertTrue(checked.text.contains("· The edge: every read works.") && checked.text.contains("· Zero Trust: the account does not use it"), checked.text)
        XCTAssertTrue(checked.text.contains("The sign-in holds the scopes account-settings.read, teams.read") && checked.text.contains("offline_access")
                      && checked.text.contains(Self.clientID), "it reports the sign-in's scopes and the client they are granted to: \(checked.text)")
        XCTAssertFalse(checked.text.contains("API token") || checked.text.contains("Token"), checked.text)
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" || $0.url?.path == "/client/v4/graphql" }, "only reads")
        XCTAssertFalse(service.requests.contains { $0.url?.path.contains("tokens") == true }, "no token is verified or listed")

        let refused = FakeService()
        refused.answers["/client/v4/zones"] = (403, #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#)
        let lacking = try await call("check-access", "{}", refused)
        XCTAssertTrue(lacking.text.contains("✗ Zones: the sign-in lacks the scope zone.read"), lacking.text)
        let dead = FakeService()
        dead.answers["\(account)/audit_logs"] = (401, #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#)
        let rejected = try await call("check-access", "{}", dead)
        XCTAssertTrue(rejected.text.contains("✗ The account audit log: Cloudflare did not accept the sign-in"), rejected.text)
    }
}
