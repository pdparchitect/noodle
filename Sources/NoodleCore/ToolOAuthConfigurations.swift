import Foundation

enum ToolOAuthConfigurations {
    static func google(scopes: [String]) -> MCPOAuthConfiguration {
        .google(scopes: scopes, clients: googleClients)
    }

    private static let googleClients = [
        googleClient(id: "183234845746-flond96hao8g0cll1boruegemodo9fe5.apps.googleusercontent.com",
                     bundleIdentifier: "com.pdparchitect.noodle"),
        googleClient(id: "183234845746-9homesnd85b490uj2ak37rpk0svtveap.apps.googleusercontent.com",
                     bundleIdentifier: "com.pdparchitect.noodle.local")
    ]

    private static func googleClient(id: String, bundleIdentifier: String) -> MCPOAuthClientConfiguration {
        .google(id: id, bundleIdentifier: bundleIdentifier)
    }
}

public extension MCPOAuthConfiguration {
    /// Signing in with Google through an app's own clients, one for each of its builds.
    static func google(scopes: [String], clients: [MCPOAuthClientConfiguration]) -> MCPOAuthConfiguration {
        MCPOAuthConfiguration(
            issuer: URL(string: "https://accounts.google.com")!,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            clients: clients, scopes: scopes,
            authorizationParameters: ["access_type": "offline", "prompt": "consent select_account"],
            usesResourceIndicator: false)
    }
}

public extension MCPOAuthClientConfiguration {
    /// A Google iOS client of the build with `bundleIdentifier`. Google returns to the scheme made from its ID, which
    /// that build's Info.plist lists.
    static func google(id: String, bundleIdentifier: String) -> MCPOAuthClientConfiguration {
        let scheme = id.split(separator: ".").reversed().joined(separator: ".")
        return MCPOAuthClientConfiguration(id: id, bundleIdentifier: bundleIdentifier, redirectURI: URL(string: scheme + ":/oauth2callback")!)
    }
}
