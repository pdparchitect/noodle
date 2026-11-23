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
    /// Where a device sign-in starts, for a service that signs native apps in that way: the person approves a code
    /// on the service's page instead of being sent back to the app, which needs no client secret.
    public let deviceAuthorizationEndpoint: URL?

    public init(issuer: URL, authorizationEndpoint: URL, tokenEndpoint: URL,
                clients: [MCPOAuthClientConfiguration], scopes: [String],
                authorizationParameters: [String: String] = [:], usesResourceIndicator: Bool = true, revocationEndpoint: URL? = nil,
                deviceAuthorizationEndpoint: URL? = nil) {
        self.revocationEndpoint = revocationEndpoint
        self.deviceAuthorizationEndpoint = deviceAuthorizationEndpoint
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
                              usesResourceIndicator: usesResourceIndicator, revocationEndpoint: revocationEndpoint,
                              deviceAuthorizationEndpoint: deviceAuthorizationEndpoint)
    }

    /// The same sign-in with every address at `host`, for a service whose sign-in server is each account's own; nil
    /// unless `host` is a host alone and every address stays https on its default port, so only the host changes.
    func at(host: String) -> MCPOAuthConfiguration? {
        // Checked as a host field checks it, and as it keeps it: lowercase labels of letters, digits and hyphens.
        guard (try? ToolField(key: "host", title: "Host", placeholder: "", kind: .host).validated(host)) == host else { return nil }
        func moved(_ url: URL) -> URL? {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "https",
                  components.port == nil, components.user == nil, components.password == nil else { return nil }
            components.host = host
            guard let moved = components.url, moved.host == host, moved.scheme == "https", moved.port == nil else { return nil }
            return moved
        }
        guard let issuer = moved(issuer), let authorization = moved(authorizationEndpoint), let token = moved(tokenEndpoint) else { return nil }
        var revocation: URL?, device: URL?
        if let revocationEndpoint { guard let url = moved(revocationEndpoint) else { return nil }; revocation = url }
        if let deviceAuthorizationEndpoint { guard let url = moved(deviceAuthorizationEndpoint) else { return nil }; device = url }
        return MCPOAuthConfiguration(issuer: issuer, authorizationEndpoint: authorization, tokenEndpoint: token,
                                     clients: clients, scopes: scopes, authorizationParameters: authorizationParameters,
                                     usesResourceIndicator: usesResourceIndicator, revocationEndpoint: revocation,
                                     deviceAuthorizationEndpoint: device)
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
