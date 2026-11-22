import Foundation
import NoodleCore
@testable import PionCore
import XCTest

/// Looks a file up by its hash, keeping only what an analyst needs.
private struct FileReport: ServiceOperation {
    struct Input: Decodable, Sendable { let hash: String; let relationships: Bool? }
    static let name = "file-report"
    static let summary = "A file's reputation by its hash."
    static let input = JSONSchema.object([
        "hash": .string("MD5, SHA-1 or SHA-256 of the file."),
        "relationships": .boolean("Whether to include related domains."),
    ], required: ["hash"])

    func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
        struct Report: Decodable { struct Data: Decodable { let id: String; let verdict: String }; let data: Data }
        let report: Report = try await service.get(["files", input.hash], query: ["relationships": input.relationships == true ? "domains" : nil])
        return try ServiceResult(text: "\(report.data.id) is \(report.data.verdict).", structured: ["verdict": report.data.verdict])
    }
}

final class ServiceAdapterTests: XCTestCase {
    private let connection = try! ToolConnection(name: "Lookup", endpoint: URL(string: "https://api.lookup.example/api/v3")!,
                                                      tokenHeader: "x-apikey", adapter: "lookup")
    private let adapter = OperationAdapter(operations: [FileReport()])

    private func call(_ arguments: String, on service: FakeService) async throws -> [String: Any] {
        let data = try await adapter.run("file-report", arguments: Data(arguments.utf8), connection: connection, access: service)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAnAdapterListsItsOperationsWithTheirSchemas() async throws {
        let list = try JSONSerialization.jsonObject(with: try await adapter.tools(for: connection)) as! [String: Any]
        let tool = try XCTUnwrap((list["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["name"] as? String, "file-report")
        XCTAssertEqual(tool["description"] as? String, "A file's reputation by its hash.")
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["required"] as? [String], ["hash"])
        XCTAssertEqual(((schema["properties"] as? [String: Any])?["relationships"] as? [String: Any])?["type"] as? String, "boolean")
        XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
    }

    func testAnOperationCallsItsServiceBelowTheConnectionsAddressAndShapesTheResult() async throws {
        let service = FakeService()
        service.answers["/api/v3/files/abc?relationships=domains"] = (200, #"{"data":{"id":"abc","verdict":"harmless","noise":[1,2,3]}}"#)
        let result = try await call(#"{"hash":"abc","relationships":true}"#, on: service)
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(((result["content"] as? [[String: Any]])?.first?["text"]) as? String, "abc is harmless.")
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["verdict"] as? String, "harmless")
        XCTAssertEqual(service.requests.first?.httpMethod, "GET")
        XCTAssertEqual(service.requests.first?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testFailuresReachTheAgentAsErrorsItCanActOn() async throws {
        let service = FakeService()
        service.answers["/api/v3/files/bad"] = (401, #"{"error":"WrongCredentials"}"#)
        service.answers["/api/v3/files/busy"] = (429, "{}")
        service.answers["/api/v3/files/denied"] = (403, #"{"detail":"You do not have permission\nto perform this action."}"#)
        service.answers["/api/v3/files/unready"] = (400, #"{"error":{"code":400,"message":"Security Command Center is not activated for this organization.","status":"FAILED_PRECONDITION"}}"#)
        service.answers["/api/v3/files/disabled"] = (403, #"{"error":{"code":403,"message":"Cloud Asset API has not been used in project 1234 before or it is disabled.","status":"PERMISSION_DENIED"}}"#)
        func message(_ arguments: String) async throws -> String {
            let result = try await call(arguments, on: service)
            XCTAssertEqual(result["isError"] as? Bool, true, arguments)
            return ((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? ""
        }
        let missing = try await message(#"{"hash":"unknown"}"#)
        XCTAssertTrue(missing.contains("not found"), missing)
        let rejected = try await message(#"{"hash":"bad"}"#)
        XCTAssertTrue(rejected.contains("rejected"), rejected)
        XCTAssertTrue(rejected.contains("(it said: WrongCredentials)"), rejected)
        // Accepted credentials that may not do this are told apart from refused ones, in the service's own words.
        let denied = try await message(#"{"hash":"denied"}"#)
        XCTAssertTrue(denied.contains("accepted this connection's credentials, but they may not do this"), denied)
        XCTAssertTrue(denied.contains("(it said: You do not have permission to perform this action.)"), denied)
        // Google and Microsoft put it one level down.
        let disabled = try await message(#"{"hash":"disabled"}"#)
        XCTAssertTrue(disabled.contains("(it said: Cloud Asset API has not been used in project 1234 before or it is disabled.)"), disabled)
        // A request the service turned down says why, when it did.
        let unready = try await message(#"{"hash":"unready"}"#)
        XCTAssertTrue(unready.contains("Security Command Center is not activated for this organization."), unready)
        let limited = try await message(#"{"hash":"busy"}"#)
        XCTAssertTrue(limited.contains("rate"), limited)
        let malformed = try await message(#"{"relationships":true}"#)
        XCTAssertTrue(malformed.contains("hash"), malformed)
        do { _ = try await adapter.run("nothing", arguments: Data("{}".utf8), connection: connection, access: service); XCTFail() } catch {}
    }

    func testAValueCannotMakeAPathOutsideItsOperation() async throws {
        let service = FakeService()
        for value in ["../../admin", "a/b", "abc?x=1", "abc#y", "..", "."] {
            let result = try await call(#"{"hash":"\#(value)"}"#, on: service)
            XCTAssertEqual(result["isError"] as? Bool, true, value)
        }
        XCTAssertTrue(service.requests.isEmpty, "a request went out for a value that leaves its path")
    }

    /// Audits that ask once per user, team or admin keep to a few requests at a time, so a large org does not trip the
    /// service's limit on requests at once.
    func testAdaptersThatAskOncePerItemPaceThemselves() {
        XCTAssertEqual(CrowdStrike.adapter.simultaneousRequests, 8)
        XCTAssertEqual(GitHub.adapter.simultaneousRequests, 8)
        XCTAssertEqual(Okta.adapter.simultaneousRequests, 8)
    }
}

