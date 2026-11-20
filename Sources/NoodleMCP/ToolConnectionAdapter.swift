import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NoodleCore

/// Answers for the connections an app serves itself rather than through an MCP server: the app's own code
/// calling a service's API. Results are shaped as MCP's, so bots use them as they use any other connection.
public protocol ToolConnectionAdapter: Sendable {
    /// The tools, as an MCP tools/list result.
    func tools(for connection: ToolConnection) async throws -> Data
    /// One call with its JSON arguments, as an MCP tools/call result. `access` reaches the service with the
    /// connection's credentials.
    func call(_ tool: String, arguments: Data, connection: ToolConnection, access: ToolConnectionAccess) async throws -> Data
    /// The tool that reads in full what `alerts` finds, for an adapter whose service has a feed of new and serious things,
    /// which the app then watches for every connection it serves; nil for one without, such as a lookup service.
    var watchedTool: String? { get }
    /// What the service raised from `since` on, at most `ServiceAlert.most` of it, newest first.
    func alerts(since: Date, connection: ToolConnection, access: ToolConnectionAccess) async throws -> [ServiceAlert]
}

public extension ToolConnectionAdapter {
    var watchedTool: String? { nil }
    func alerts(since: Date, connection: ToolConnection, access: ToolConnectionAccess) async throws -> [ServiceAlert] { [] }
}

/// How an adapter reaches its service: only the connection's own host, over its own scheme (HTTPS, or HTTP for a
/// service on this Mac or the local network), with the connection's credentials added and never shown to it. Redirects are not followed, so they cannot carry the credentials away.
public struct ToolConnectionAccess: Sendable {
    let endpoint: URL
    let authorization: ConnectionAuthorization?
    let configuration: @Sendable () -> URLSessionConfiguration
    static let limit = 8 * 1_048_576
    private func url(_ request: URLRequest) -> URL? { request.url }

    /// For an AWS connection signed in through IAM Identity Center: every account its sign-in covers.
    public func awsAccounts() async throws -> [AWSAccount] {
        guard case .awsOrganisation(let organisation)? = authorization else { throw Self.notIdentityCenter }
        return try await organisation.accounts()
    }

    /// The same access, signing as the connection's role in one of the accounts its sign-in covers.
    public func awsAccount(_ id: String) async throws -> ToolConnectionAccess {
        guard case .awsOrganisation(let organisation)? = authorization else { throw Self.notIdentityCenter }
        return ToolConnectionAccess(endpoint: endpoint, authorization: .aws(try await organisation.keys(id), defaultRegion: organisation.region),
                                    configuration: configuration)
    }

    private static let notIdentityCenter = ToolConnectionError.message("This connection does not sign in through AWS IAM Identity Center.")

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // An organisation's sign-in signs nothing itself: each request goes as one account's role.
        if case .awsOrganisation? = authorization { throw ToolConnectionError.message("Name the AWS account the request is for.") }
        // Only the connection's host; an AWS connection, any AWS service below it, since each request is signed for one.
        let host = url(request)?.host?.lowercased() ?? "", home = endpoint.host?.lowercased() ?? ""
        let reachable = host == home || (authorization?.coversSubdomains == true && host.hasSuffix("." + home))
        guard let url = request.url, url.scheme?.lowercased() == endpoint.scheme?.lowercased(), reachable, url.port == endpoint.port, url.user == nil else {
            throw ToolConnectionError.message("A tool adapter may only reach its own service.")
        }
        var request = request
        authorization?.apply(to: &request)
        // The guard on MCP traffic takes only public HTTPS and turns every answer but a success into an error. An adapter
        // checks its own requests above, and reads the service's status to say what went wrong, so it goes without it.
        let configuration = configuration()
        configuration.protocolClasses = configuration.protocolClasses?.filter { $0 != MCPGuardedHTTP.self }
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request, limit: Self.limit, tooLarge: ToolConnectionServiceError.responseTooLarge)
        guard let http = response as? HTTPURLResponse else { throw ToolConnectionServiceError.network(0) }
        return (data, http)
    }
}

/// An AWS account a connection signed in through IAM Identity Center may use.
public struct AWSAccount: Equatable, Sendable {
    public let id: String
    public let name: String
    public let email: String?
    public init(id: String, name: String, email: String?) { self.id = id; self.name = name; self.email = email }
}

/// What an AWS connection signed in through Identity Center reaches: the accounts its sign-in covers, and keys for the
/// connection's role in one of them, got when first asked for.
struct AWSOrganisation: Sendable {
    /// Where requests go unless they name another region.
    let region: String
    let accounts: @Sendable () async throws -> [AWSAccount]
    let keys: @Sendable (String) async throws -> ConnectionAWSKey
}

/// How a request proves who its connection is: a header, or for a service that takes its key only there, a
/// parameter in its address.
enum ConnectionAuthorization: Sendable {
    case header(String, String)
    case parameter(String, String)
    /// Signed with one account's AWS keys, for the service and region each request's address names.
    case aws(ConnectionAWSKey, defaultRegion: String)
    /// An organisation's Identity Center sign-in, which signs as one of its accounts once the adapter names it.
    case awsOrganisation(AWSOrganisation)
    /// A Google access token, good for every googleapis.com service its scopes allow.
    case google(String)

    /// Whether it reaches every service below its connection's host, as an AWS key or a Google token does.
    var coversSubdomains: Bool {
        switch self {
        case .aws, .awsOrganisation, .google: true
        case .header, .parameter: false
        }
    }

    func apply(to request: inout URLRequest) {
        switch self {
        case .header(let name, let value):
            request.setValue(value, forHTTPHeaderField: name)
        case .google(let token):
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        case .parameter(let name, let value):
            guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            components.queryItems = (components.queryItems ?? []).filter { $0.name != name } + [URLQueryItem(name: name, value: value)]
            // A token may hold characters a query keeps as they are, such as + and /.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F")
            request.url = components.url ?? url
        case .aws(let key, let defaultRegion):
            guard let host = request.url?.host, let scope = AWSSignature.scope(of: host, defaultRegion: defaultRegion) else { return }
            AWSSignature.sign(&request, key: key, region: scope.region, service: scope.service)
        case .awsOrganisation:
            break
        }
    }
}
