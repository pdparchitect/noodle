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

    public init(issuer: URL, authorizationEndpoint: URL, tokenEndpoint: URL,
                clients: [MCPOAuthClientConfiguration], scopes: [String],
                authorizationParameters: [String: String] = [:], usesResourceIndicator: Bool = true) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clients = clients
        self.scopes = scopes
        self.authorizationParameters = authorizationParameters
        self.usesResourceIndicator = usesResourceIndicator
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
