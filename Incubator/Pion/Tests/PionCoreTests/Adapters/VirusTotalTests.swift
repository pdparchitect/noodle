import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class VirusTotalTests: XCTestCase {
    private let connection = try! VirusTotal.preset.makeConnection(name: "VirusTotal")
    private let sha256 = String(repeating: "ab", count: 32)

    private func call(_ tool: String, _ arguments: String, on service: FakeService) async throws -> (text: String, isError: Bool, structured: [String: Any]?) {
        let data = try await VirusTotal.adapter.run(tool, arguments: Data(arguments.utf8), connection: connection, access: service)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? "", result["isError"] as? Bool ?? false,
                result["structuredContent"] as? [String: Any])
    }

    private func object(_ attributes: String, id: String = "x") -> String {
        #"{"data":{"id":"\#(id)","type":"t","attributes":{"last_analysis_stats":{"harmless":60,"malicious":3,"suspicious":1,"undetected":6,"timeout":0},"reputation":-12,"last_analysis_date":1700000000,"tags":["phishing"],"#
            + attributes + "}}}"
    }

    func testThePresetIsAnAPIKeyAccountServedByPionsAdapter() throws {
        XCTAssertEqual(connection.adapter, "virustotal")
        XCTAssertEqual(connection.tokenHeader, "x-apikey")
        XCTAssertEqual(connection.endpoint.absoluteString, "https://www.virustotal.com/api/v3")
        XCTAssertNotNil(PionAdapters.all["virustotal"])
    }

    func testItOffersLookupsForFilesDomainsAddressesAndURLs() async throws {
        let list = try JSONSerialization.jsonObject(with: try await VirusTotal.adapter.tools(for: connection)) as! [String: Any]
        XCTAssertEqual(Set((list["tools"] as! [[String: Any]]).compactMap { $0["name"] as? String }),
                       ["file-report", "domain-report", "ip-report", "url-report", "check-access"])
    }

    func testAFileReportSaysHowManyEnginesFlagItAndKeepsTheFileDetails() async throws {
        let service = FakeService()
        service.answers["/api/v3/files/\(sha256)"] = (200, object(#""meaningful_name":"invoice.exe","type_description":"Win32 EXE","size":4096,"sha256":"\#(sha256)","first_submission_date":1690000000"#, id: sha256))
        let result = try await call("file-report", #"{"hash":"\#(sha256.uppercased())"}"#, on: service)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("3 of 70"), result.text)
        XCTAssertTrue(result.text.contains("invoice.exe"), result.text)
        XCTAssertEqual(result.structured?["malicious"] as? Int, 3)
        XCTAssertEqual(result.structured?["name"] as? String, "invoice.exe")
        XCTAssertEqual(result.structured?["lastAnalysis"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(result.structured?["link"] as? String, "https://www.virustotal.com/gui/file/\(sha256)")
    }

    func testDomainAddressAndURLReportsAskForTheRightObjects() async throws {
        let service = FakeService()
        service.answers["/api/v3/domains/payroll-kestrel.example"] = (200, object(#""registrar":"NameCheap","creation_date":1699900000"#))
        service.answers["/api/v3/ip_addresses/203.0.113.77"] = (200, object(#""as_owner":"Example Hosting","asn":64500,"country":"NL","network":"203.0.113.0/24""#))
        let url = "https://payroll-kestrel.example/login?next=a"
        let id = Data(url.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        service.answers["/api/v3/urls/\(id)"] = (200, object(#""url":"\#(url)","final_url":"\#(url)","title":"Sign in""#))

        let domain = try await call("domain-report", #"{"domain":"Payroll-Kestrel.example"}"#, on: service)
        XCTAssertEqual(domain.structured?["registrar"] as? String, "NameCheap")
        let address = try await call("ip-report", #"{"ip":"203.0.113.77"}"#, on: service)
        XCTAssertEqual(address.structured?["owner"] as? String, "Example Hosting")
        XCTAssertTrue(address.text.contains("NL"), address.text)
        let page = try await call("url-report", #"{"url":"\#(url)"}"#, on: service)
        XCTAssertFalse(page.isError, page.text)
        XCTAssertEqual(page.structured?["title"] as? String, "Sign in")
    }

    func testBadValuesAreRefusedBeforeAnythingIsSent() async throws {
        let service = FakeService()
        for (tool, arguments) in [("file-report", #"{"hash":"not-a-hash"}"#), ("file-report", #"{"hash":"abc"}"#),
                                  ("domain-report", #"{"domain":"localhost"}"#), ("ip-report", #"{"ip":"999.1.1.1"}"#),
                                  ("url-report", #"{"url":"file:///etc/passwd"}"#)] {
            let result = try await call(tool, arguments, on: service)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testSomethingVirusTotalHasNeverSeenIsSaidPlainly() async throws {
        let result = try await call("file-report", #"{"hash":"\#(sha256)"}"#, on: FakeService())
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("not found"), result.text)
    }

    func testCheckAccessSpendsOneLookup() async throws {
        let service = FakeService()
        service.answers["/api/v3/ip_addresses/8.8.8.8"] = (200, #"{"data":{"id":"8.8.8.8","attributes":{}}}"#)
        let access = try await callTool(VirusTotal.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("✓ API key (a lookup of 8.8.8.8, which spent one): it works"), access.text)
        XCTAssertEqual(service.requests.count, 1)
    }

    func testCheckAccessSaysWhatToChangeForAKeyVirusTotalRefusesOrASpentQuota() async throws {
        let service = FakeService()
        service.answers["/api/v3/ip_addresses/8.8.8.8"] = (401, #"{"error":{"code":"WrongCredentialsError","message":"Wrong API key"}}"#)
        let wrong = try await callTool(VirusTotal.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertTrue(wrong.text.contains("✗ API key (a lookup of 8.8.8.8, which spent one): VirusTotal did not accept the key"), wrong.text)
        service.answers["/api/v3/ip_addresses/8.8.8.8"] = (429, #"{"error":{"code":"QuotaExceededError","message":"Quota exceeded"}}"#)
        let spent = try await callTool(VirusTotal.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertTrue(spent.text.contains("500 a day, renewed at midnight UTC"), spent.text)
    }
}
