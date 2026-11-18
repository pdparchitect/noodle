import Foundation

/// Public client configuration supplied by an MCP catalogue entry.
public struct MCPOAuthConfiguration: Equatable, Sendable {
    public let issuer: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let clients: [MCPOAuthClientConfiguration]
    public let scopes: [String]
    public let authorizationParameters: [String: String]
    public let usesResourceIndicator: Bool
    /// Where a sign-in is revoked at the service, for one that offers it.
    public let revocationEndpoint: URL?

    public init(issuer: URL, authorizationEndpoint: URL, tokenEndpoint: URL,
                clients: [MCPOAuthClientConfiguration], scopes: [String],
                authorizationParameters: [String: String] = [:], usesResourceIndicator: Bool = true, revocationEndpoint: URL? = nil) {
        self.revocationEndpoint = revocationEndpoint
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clients = clients
        self.scopes = scopes
        self.authorizationParameters = authorizationParameters
        self.usesResourceIndicator = usesResourceIndicator
    }
}

public extension MCPOAuthConfiguration {
    /// The same sign-in through other clients.
    func with(clients: [MCPOAuthClientConfiguration]) -> MCPOAuthConfiguration {
        MCPOAuthConfiguration(issuer: issuer, authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint,
                              clients: clients, scopes: scopes, authorizationParameters: authorizationParameters,
                              usesResourceIndicator: usesResourceIndicator, revocationEndpoint: revocationEndpoint)
    }
}

public struct MCPOAuthClientConfiguration: Equatable, Sendable {
    public let id: String
    public let bundleIdentifier: String
    public let redirectURI: URL

    public init(id: String, bundleIdentifier: String, redirectURI: URL) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.redirectURI = redirectURI
    }
}
