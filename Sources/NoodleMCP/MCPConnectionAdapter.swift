import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NoodleCore

/// Answers for the connections an app serves itself rather than through an MCP server: the app's own code
/// calling a service's API. Results are shaped as MCP's, so bots use them as they use any other connection.
public protocol MCPConnectionAdapter: Sendable {
    /// The tools, as an MCP tools/list result.
    func tools(for connection: MCPConnectionRecord) async throws -> Data
    /// One call with its JSON arguments, as an MCP tools/call result. `access` reaches the service with the
    /// connection's credentials.
    func call(_ tool: String, arguments: Data, connection: MCPConnectionRecord, access: MCPAdapterAccess) async throws -> Data
}

/// How an adapter reaches its service: only the connection's own host, over HTTPS, with the connection's
/// credentials added and never shown to it. Redirects are not followed, so they cannot carry the credentials away.
public struct MCPAdapterAccess: Sendable {
    let endpoint: URL
    let authorization: (header: String, value: String)?
    let configuration: @Sendable () -> URLSessionConfiguration
    static let limit = 8 * 1_048_576

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              url.host?.lowercased() == endpoint.host?.lowercased(), url.port == endpoint.port, url.user == nil else {
            throw MCPConnectionError.message("A tool adapter may only reach its own service.")
        }
        var request = request
        if let authorization { request.setValue(authorization.value, forHTTPHeaderField: authorization.header) }
        let session = URLSession(configuration: configuration(), delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request, limit: Self.limit, tooLarge: MCPServiceError.responseTooLarge)
        guard let http = response as? HTTPURLResponse else { throw MCPServiceError.network(0) }
        return (data, http)
    }
}
