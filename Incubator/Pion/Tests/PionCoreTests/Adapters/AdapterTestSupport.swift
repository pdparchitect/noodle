import Foundation
import NoodleCore
@testable import PionCore
import XCTest

/// A service that answers from a table and records what it was asked.
final class FakeService: ServiceAccess, @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    var answers: [String: (Int, String)] = [:]

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let key = request.url!.path + (request.url!.query.map { "?" + $0 } ?? "")
        let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "Action" }?.value
        // An answer for the request's target or action first, as AWS names its calls, then an exact one, then one for
        // the path whatever the query.
        let candidates = [request.value(forHTTPHeaderField: "X-Amz-Target"), action.map { "action:" + $0 }, key, request.url!.path]
        let (status, body) = lock.withLock { candidates.lazy.compactMap { $0 }.compactMap { self.answers[$0] }.first }
            ?? (404, #"{"error":"NotFound"}"#)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// What a tool call returned: its text, whether it failed, and its structured result.
struct AdapterResult {
    let text: String
    let isError: Bool
    let structured: [String: Any]?
}

/// Runs `tool` of `adapter` for `connection` against a stand-in service.
func callTool(_ adapter: OperationAdapter, _ tool: String, _ arguments: String, on service: FakeService,
         in connection: MCPConnectionRecord) async throws -> AdapterResult {
    let data = try await adapter.run(tool, arguments: Data(arguments.utf8), connection: connection, access: service)
    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return AdapterResult(text: ((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? "",
                         isError: result["isError"] as? Bool ?? false, structured: result["structuredContent"] as? [String: Any])
}

/// A request's query values by name.
func queryItems(_ request: URLRequest?) -> [String: String] {
    let items = request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

/// A form-encoded request body's values by name.
func formItems(_ request: URLRequest?) -> [String: String] {
    let body = String(data: request?.httpBody ?? Data(), encoding: .utf8) ?? ""
    let items = URLComponents(string: "https://form/?" + body)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}
