import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class CrtShTests: XCTestCase {
    private let connection = try! CrtSh.preset.makeConnection(name: "crt.sh")

    private static func certificate(_ id: Int, names: [String], logged: String, until: String,
                                    issuer: String = "C=US, O=Let's Encrypt, CN=R11") -> String {
        #"{"issuer_ca_id":1,"issuer_name":"\#(issuer)","common_name":"\#(names[0])","name_value":"\#(names.joined(separator: "\\n"))","id":\#(id),"entry_timestamp":"\#(logged)T10:00:00.000","not_before":"\#(logged)T09:00:00","not_after":"\#(until)T09:00:00","serial_number":"0a"}"#
    }

    func testADomainsCertificatesShowItsNamesAndTheOtherDomainsTheyCoverNewestFirst() async throws {
        XCTAssertEqual(connection.endpoint.absoluteString, "https://crt.sh")
        XCTAssertFalse(connection.keepsSecret, "crt.sh answers without a key")
        XCTAssertNotNil(PionAdapters.all["crtsh"])
        let service = FakeService()
        service.answers["/"] = (200, "[" + [
            Self.certificate(101, names: ["example.com", "www.example.com"], logged: "2026-09-01", until: "2026-11-30"),
            Self.certificate(303, names: ["vpn.example.com", "VPN.example.com", "*.dev.example.com", "example-staging.net"], logged: "2026-11-10",
                             until: "2027-02-08", issuer: "C=US, O=Google Trust Services, CN=WE1"),
            Self.certificate(202, names: ["mail.example.com"], logged: "2026-10-01", until: "2026-12-30"),
        ].joined(separator: ",") + "]")
        let result = try await callTool(CrtSh.adapter, "certificates", #"{"domain":"*.Example.com"}"#, on: service, in: connection)
        XCTAssertFalse(result.isError, result.text)
        let sent = queryItems(service.requests.first)
        XCTAssertEqual(sent["q"], "%.example.com")
        XCTAssertEqual(sent["output"], "json")
        XCTAssertEqual(sent["exclude"], "expired")
        XCTAssertEqual(sent["deduplicate"], "Y")
        for expected in ["3 current certificates", "*.dev.example.com", "example.com", "mail.example.com", "vpn.example.com", "www.example.com",
                         "Other domains on the same certificates: example-staging.net",
                         "2026-11-10, valid until 2027-02-08, Google Trust Services WE1: vpn.example.com, *.dev.example.com, example-staging.net (crt.sh/?id=303)"] {
            XCTAssertTrue(result.text.contains(expected), "\(expected) missing from:\n\(result.text)")
        }
        XCTAssertEqual(result.text.components(separatedBy: "VPN.example.com").count, 1, "a name was listed twice in another case")
        let newest = try XCTUnwrap(result.text.range(of: "crt.sh/?id=303")), oldest = try XCTUnwrap(result.text.range(of: "crt.sh/?id=101"))
        XCTAssertLessThan(newest.lowerBound, oldest.lowerBound, "not newest first")

        _ = try await callTool(CrtSh.adapter, "certificates", #"{"domain":"example.com","subdomains":false,"expired":true}"#,
                               on: service, in: connection)
        let exact = queryItems(service.requests.last)
        XCTAssertEqual(exact["q"], "example.com")
        XCTAssertNil(exact["exclude"])

        for bad in [#"{}"#, #"{"domain":"%.example.com"}"#, #"{"domain":"localhost"}"#, #"{"domain":"a b.com"}"#,
                    #"{"domain":"example.com","limit":500}"#] {
            let refused = try await callTool(CrtSh.adapter, "certificates", bad, on: FakeService(), in: connection)
            XCTAssertTrue(refused.isError, bad)
        }
    }

    func testNoCertificatesSaysSo() async throws {
        let service = FakeService()
        service.answers["/"] = (200, "[]")
        let result = try await callTool(CrtSh.adapter, "certificates", #"{"domain":"nothing.example"}"#, on: service, in: connection)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("crt.sh has no current certificate for nothing.example"), result.text)
    }

    func testABusyCrtShSaysToTryLaterAndToNarrowTheSearch() async throws {
        for status in [502, 503, 504] {
            let service = FakeService()
            service.answers["/"] = (status, "<html>busy</html>")
            let result = try await callTool(CrtSh.adapter, "certificates", #"{"domain":"example.com"}"#, on: service, in: connection)
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.text.contains("crt.sh is busy"), result.text)
        }
        let service = FakeService()
        service.answers["/"] = (200, "<html>Sorry, something went wrong</html>")
        let result = try await callTool(CrtSh.adapter, "certificates", #"{"domain":"example.com"}"#, on: service, in: connection)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("crt.sh is busy"), result.text)
    }
}
