import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class DNSTests: XCTestCase {
    private let connection = try! DNS.preset.makeConnection(name: "DNS")

    /// Google Public DNS's answer to one question, as its JSON API gives it.
    private static func answer(_ name: String, _ type: Int, _ data: [String]) -> (Int, String) {
        let records = data.map { #"{"name":"\#(name).","type":\#(type),"TTL":300,"data":"\#($0.replacingOccurrences(of: "\"", with: "\\\""))"}"# }
        return (200, #"{"Status":0,"Question":[{"name":"\#(name).","type":\#(type)}],"Answer":[\#(records.joined(separator: ","))]}"#)
    }

    private static let nothing = (200, #"{"Status":0,"Question":[{"name":"x.","type":16}]}"#)

    func testRecordsListEachTypeAndSayWhenANameDoesNotExist() async throws {
        XCTAssertEqual(connection.endpoint.absoluteString, "https://dns.google")
        XCTAssertFalse(connection.keepsSecret, "Google Public DNS answers without a key")
        XCTAssertNotNil(PionAdapters.all["dns"])
        let service = FakeService()
        service.answers["/resolve?name=example.com&type=MX"] = Self.answer("example.com", 15, ["1 smtp.google.com."])
        service.answers["/resolve?name=example.com&type=TXT"] = Self.answer("example.com", 16, [#""v=spf1 include:_spf.google.com " "-all""#])
        service.answers["/resolve"] = Self.nothing
        let result = try await callTool(DNS.adapter, "records", #"{"name":"Example.com.","types":["MX","TXT"]}"#, on: service, in: connection)
        XCTAssertFalse(result.isError, result.text)
        for expected in ["MX: 1 smtp.google.com.", "TXT: v=spf1 include:_spf.google.com -all"] {
            XCTAssertTrue(result.text.contains(expected), "\(expected) missing from:\n\(result.text)")
        }
        service.answers["/resolve?name=gone.example.com&type=A"] = (200, #"{"Status":3}"#)
        let gone = try await callTool(DNS.adapter, "records", #"{"name":"gone.example.com","types":["A"]}"#, on: service, in: connection)
        XCTAssertTrue(gone.text.contains("gone.example.com does not exist"), gone.text)
    }

    func testAnAddressIsLookedUpBackwards() async throws {
        let service = FakeService()
        service.answers["/resolve?name=4.3.2.192.in-addr.arpa&type=PTR"] = Self.answer("4.3.2.192.in-addr.arpa", 12, ["mail.example.com."])
        let result = try await callTool(DNS.adapter, "records", #"{"name":"192.2.3.4"}"#, on: service, in: connection)
        XCTAssertTrue(result.text.contains("PTR: mail.example.com."), result.text)
    }

    func testEmailSecurityReadsSPFDMARCDKIMAndSaysWhatIsWeak() async throws {
        let service = FakeService()
        service.answers["/resolve"] = Self.nothing
        service.answers["/resolve?name=example.com&type=MX"] = Self.answer("example.com", 15, ["1 smtp.google.com."])
        service.answers["/resolve?name=example.com&type=TXT"] = Self.answer("example.com", 16, [
            "v=spf1 include:_spf.google.com include:mail.vendor.example ~all", "google-site-verification=abc"])
        service.answers["/resolve?name=_spf.google.com&type=TXT"] = Self.answer("_spf.google.com", 16, ["v=spf1 ip4:74.125.0.0/16 ~all"])
        service.answers["/resolve?name=mail.vendor.example&type=TXT"] = Self.answer("mail.vendor.example", 16, ["v=spf1 a mx include:more.vendor.example ?all"])
        service.answers["/resolve?name=more.vendor.example&type=TXT"] = Self.answer("more.vendor.example", 16, ["v=spf1 ip4:192.0.2.0/24 -all"])
        service.answers["/resolve?name=_dmarc.example.com&type=TXT"] = Self.answer("_dmarc.example.com", 16, ["v=DMARC1; p=none; pct=50"])
        service.answers["/resolve?name=google._domainkey.example.com&type=TXT"] = Self.answer("google._domainkey.example.com", 16,
                                                                                               ["v=DKIM1; k=rsa; p=MIIBIjAN"])
        service.answers["/resolve?name=selector1._domainkey.example.com&type=TXT"] = Self.answer("selector1._domainkey.example.com", 16, ["v=DKIM1; p="])
        let result = try await callTool(DNS.adapter, "email-security", #"{"domain":"example.com"}"#, on: service, in: connection)
        XCTAssertFalse(result.isError, result.text)
        for expected in [
            "Mail goes to: 1 smtp.google.com. (Google)",
            "SPF: v=spf1 include:_spf.google.com include:mail.vendor.example ~all",
            "ends ~all: mail from other servers is marked suspicious but usually delivered",
            "5 of the 10 DNS lookups SPF allows",
            "DMARC: v=DMARC1; p=none; pct=50",
            "p=none: spoofed mail is reported, not stopped",
            "pct=50: the policy covers only half",
            "no rua=",
            "DKIM google: published (rsa)",
            "DKIM selector1: revoked (empty key)",
            "DKIM selector2: none",
            "MTA-STS: none", "TLS reporting: none",
        ] {
            XCTAssertTrue(result.text.contains(expected), "\(expected) missing from:\n\(result.text)")
        }
    }

    func testEmailSecuritySaysWhenSPFOrDMARCIsMissingOrBroken() async throws {
        let service = FakeService()
        service.answers["/resolve"] = Self.nothing
        service.answers["/resolve?name=example.com&type=TXT"] = Self.answer("example.com", 16, ["v=spf1 -all", "v=spf1 +all"])
        let result = try await callTool(DNS.adapter, "email-security", #"{"domain":"example.com","selectors":["s1"]}"#, on: service, in: connection)
        for expected in ["2 SPF records: receivers treat that as an error", "DMARC: none", "anyone can send as example.com", "DKIM s1: none",
                         "No MX records"] {
            XCTAssertTrue(result.text.contains(expected), "\(expected) missing from:\n\(result.text)")
        }
        XCTAssertFalse(result.text.contains("DKIM google"), "selectors given replace the usual ones")
    }

    func testASelfIncludingSPFStopsCounting() async throws {
        let service = FakeService()
        service.answers["/resolve"] = Self.nothing
        service.answers["/resolve?name=example.com&type=TXT"] = Self.answer("example.com", 16, ["v=spf1 include:example.com -all"])
        let result = try await callTool(DNS.adapter, "email-security", #"{"domain":"example.com"}"#, on: service, in: connection)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertLessThan(service.requests.filter { $0.url?.query == "name=example.com&type=TXT" }.count, 3, "followed a loop")
    }
}
