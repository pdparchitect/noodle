import Foundation
import CryptoKit
import Security
import MCP
import NoodleCore

/// OAuth metadata and token exchanges never follow redirects or carry MCP tokens.
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct MCPOAuth {
    typealias Object = [String: Any]
    let session: URLSession
    init(session: URLSession) { self.session = session }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static func preconfiguredCredentials(endpoint: URL, redirect: URL,
                                         configuration: MCPOAuthConfiguration?) throws -> MCPCredentials? {
        guard let configuration else { return nil }
        guard let client = configuration.clients.first(where: { $0.redirectURI == redirect }) else {
            throw MCPServiceError.invalidCallback
        }
        return MCPCredentials(endpoint: endpoint, issuer: configuration.issuer,
            authorizationEndpoint: configuration.authorizationEndpoint,
            tokenEndpoint: configuration.tokenEndpoint, clientID: client.id,
            redirectURI: redirect, resource: endpoint, scope: configuration.scopes.joined(separator: " "))
    }

    func validateConfiguration(_ credentials: MCPCredentials, configuration: MCPOAuthConfiguration?) throws {
        guard let configuration else { return }
        guard let expected = try Self.preconfiguredCredentials(endpoint: credentials.endpoint,
                redirect: credentials.redirectURI, configuration: configuration),
              credentials.issuer == expected.issuer, credentials.authorizationEndpoint == expected.authorizationEndpoint,
              credentials.tokenEndpoint == expected.tokenEndpoint, credentials.clientID == expected.clientID,
              credentials.resource == expected.resource else {
            throw MCPServiceError.invalidMetadata
        }
        guard Set(configuration.scopes).isSubset(of: Set((credentials.scope ?? "").split(separator: " ").map(String.init))) else {
            throw MCPServiceError.signInRequired
        }
    }

    func request(_ url: URL, json: Object? = nil, form: [String: String]? = nil) async throws -> Object {
        _ = try MCPConnectionRecord.validatedEndpoint(url)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            request.httpBody = form.sorted { $0.key < $1.key }.map {
                "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&").data(using: .utf8)
        }
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw MCPServiceError.responseTooLarge }
            data.append(byte)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? Object ?? [:]
        if object["error"] as? String == "invalid_grant" || object["error"] as? String == "invalid_client" {
            throw MCPServiceError.signInRequired
        }
        guard (200..<300).contains(status) else { throw MCPServiceError.network(status) }
        return object
    }

    /// `authorizationServer` comes from the catalogue, for services that publish no
    /// protected-resource metadata; published metadata still wins when present.
    func discoverAndRegister(endpoint: URL, redirect: URL, clientName: String, authorizationServer: URL? = nil,
                             progress: @Sendable (String) async -> Void = { _ in }) async throws -> MCPCredentials {
        await progress("Discovering authorization…")
        let discovery = DefaultOAuthMetadataDiscovery()
        var protectedResource: Object?
        for candidate in discovery.protectedResourceMetadataURLs(for: endpoint) {
            if let object = try? await request(candidate), object["authorization_servers"] is [String] {
                protectedResource = object
                break
            }
        }
        let resource: URL, issuer: URL
        if let protectedResource {
            guard let resourceString = protectedResource["resource"] as? String,
                  let published = URL(string: resourceString),
                  Self.acceptsResource(published, for: endpoint),
                  let issuers = protectedResource["authorization_servers"] as? [String],
                  let first = issuers.first, let listed = URL(string: first) else { throw MCPServiceError.invalidMetadata }
            resource = published; issuer = listed
        } else if let authorizationServer {
            resource = endpoint; issuer = authorizationServer
        } else {
            throw MCPServiceError.invalidMetadata
        }
        _ = try MCPConnectionRecord.validatedEndpoint(issuer)
        var metadata: Object?
        await progress("Checking authorization server…")
        for candidate in discovery.authorizationServerMetadataURLs(for: issuer) {
            if let object = try? await request(candidate), Self.sameIssuer(object["issuer"] as? String, as: issuer) {
                metadata = object
                break
            }
        }
        guard let metadata,
              let authString = metadata["authorization_endpoint"] as? String, let authorization = URL(string: authString),
              let tokenString = metadata["token_endpoint"] as? String, let token = URL(string: tokenString) else {
            throw MCPServiceError.invalidMetadata
        }
        _ = try MCPConnectionRecord.validatedEndpoint(authorization)
        _ = try MCPConnectionRecord.validatedEndpoint(token)
        let scope = (protectedResource?["scopes_supported"] as? [String])?.joined(separator: " ")
        guard let registrationString = metadata["registration_endpoint"] as? String,
              let registration = URL(string: registrationString) else {
            // Without registration, a service may instead read Noodle's published client
            // metadata, which only allows https addresses: hence the relay pages.
            guard metadata["client_id_metadata_document_supported"] as? Bool == true,
                  (metadata["token_endpoint_auth_methods_supported"] as? [String])?.contains("none") ?? true,
                  let relay = Self.relays[redirect.absoluteString] else { throw MCPServiceError.registrationUnsupported }
            return MCPCredentials(endpoint: endpoint, issuer: issuer, authorizationEndpoint: authorization,
                                  tokenEndpoint: token, clientID: Self.metadataDocument.absoluteString, redirectURI: redirect,
                                  relayURI: relay, resource: resource, scope: scope)
        }
        // Public desktop clients use PKCE, never embedded client secrets.
        await progress("Registering this connection…")
        let registered = try await request(registration, json: [
            "client_name": clientName, "redirect_uris": [redirect.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"], "token_endpoint_auth_method": "none"
        ])
        guard let clientID = registered["client_id"] as? String, !clientID.isEmpty,
              (registered["token_endpoint_auth_method"] as? String ?? "none") == "none" else {
            throw MCPServiceError.registrationUnsupported
        }
        return MCPCredentials(endpoint: endpoint, issuer: issuer, authorizationEndpoint: authorization,
                              tokenEndpoint: token, clientID: clientID, redirectURI: redirect,
                              resource: resource, scope: scope)
    }

    /// Published from website/oauth; its redirect_uris must list every relay below.
    static let metadataDocument = URL(string: "https://usenoodle.app/oauth/client.json")!
    static let relays: [String: URL] = [
        "noodle://mcp/oauth/callback": URL(string: "https://usenoodle.app/oauth/callback/")!,
        "noodle-dev://mcp/oauth/callback": URL(string: "https://usenoodle.app/oauth/callback/dev/")!,
        "noodle-mobile://mcp/oauth/callback": URL(string: "https://usenoodle.app/oauth/callback/mobile/")!
    ]

    /// Metadata must name the issuer it was discovered for. Some servers list it with
    /// a trailing slash and report it without, or the reverse; that is the same URL,
    /// so only that one character may differ.
    static func sameIssuer(_ reported: String?, as issuer: URL) -> Bool {
        guard let reported else { return false }
        let listed = issuer.absoluteString
        return reported == listed || reported == listed + "/" || reported + "/" == listed
    }

    /// A canonical OAuth resource may be the server origin rather than its MCP
    /// transport path (for example Pipedream's /v2). Never accept another origin
    /// or an unrelated resource path, and never change the transport destination.
    static func acceptsResource(_ resource: URL, for endpoint: URL) -> Bool {
        guard (try? MCPConnectionRecord.validatedEndpoint(resource)) != nil,
              (try? MCPConnectionRecord.validatedEndpoint(endpoint)) != nil else { return false }
        if resource == endpoint { return true }
        guard let canonical = URLComponents(url: resource, resolvingAgainstBaseURL: false),
              let transport = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return false }
        return canonical.scheme?.lowercased() == transport.scheme?.lowercased() &&
            canonical.host?.lowercased() == transport.host?.lowercased() &&
            (canonical.port ?? 443) == (transport.port ?? 443) &&
            (canonical.percentEncodedPath.isEmpty || canonical.percentEncodedPath == "/") &&
            canonical.query == nil
    }

    func authorize(_ credentials: MCPCredentials, configuration: MCPOAuthConfiguration? = nil,
                   browser: @Sendable (URL) async throws -> URL) async throws -> MCPCredentials {
        try validateConfiguration(credentials, configuration: configuration)
        let verifier = try Self.nonce()
        let state = try Self.nonce()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var components = URLComponents(url: credentials.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: credentials.clientID),
            .init(name: "redirect_uri", value: (credentials.relayURI ?? credentials.redirectURI).absoluteString),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256")
        ]
        if configuration?.usesResourceIndicator ?? true {
            components.queryItems?.append(.init(name: "resource", value: credentials.resource.absoluteString))
        }
        if let scope = credentials.scope, !scope.isEmpty { components.queryItems?.append(.init(name: "scope", value: scope)) }
        let reserved = Set((components.queryItems ?? []).map(\.name)).union(["scope", "resource", "client_secret"])
        for (name, value) in (configuration?.authorizationParameters ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !reserved.contains(name) else { throw MCPServiceError.invalidMetadata }
            components.queryItems?.append(.init(name: name, value: value))
        }
        guard let authorizationURL = components.url else { throw MCPServiceError.invalidMetadata }
        let callback = try await browser(authorizationURL)
        let expected = URLComponents(url: credentials.redirectURI, resolvingAgainstBaseURL: false)!
        guard let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme, actual.host == expected.host,
              actual.user == nil, actual.password == nil,
              actual.port == expected.port, actual.path == expected.path, actual.fragment == nil else {
            throw MCPServiceError.invalidCallback
        }
        let values = Dictionary(grouping: actual.queryItems ?? [], by: \.name)
        guard values["state"]?.count == 1, values["state"]?.first?.value == state,
              values["error"] == nil, values["code"]?.count == 1,
              let code = values["code"]?.first?.value, !code.isEmpty else { throw MCPServiceError.invalidCallback }
        var form = [
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "client_id": credentials.clientID, "redirect_uri": (credentials.relayURI ?? credentials.redirectURI).absoluteString
        ]
        if configuration?.usesResourceIndicator ?? true { form["resource"] = credentials.resource.absoluteString }
        let response = try await request(credentials.tokenEndpoint, form: form)
        return try updated(credentials, response: response, configuration: configuration)
    }

    func refresh(_ credentials: MCPCredentials, configuration: MCPOAuthConfiguration? = nil) async throws -> MCPCredentials {
        try validateConfiguration(credentials, configuration: configuration)
        guard let refreshToken = credentials.refreshToken else { throw MCPServiceError.signInRequired }
        var form = [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": credentials.clientID
        ]
        if configuration?.usesResourceIndicator ?? true { form["resource"] = credentials.resource.absoluteString }
        let response = try await request(credentials.tokenEndpoint, form: form)
        return try updated(credentials, response: response, configuration: configuration)
    }
    private func updated(_ credentials: MCPCredentials, response: Object, configuration: MCPOAuthConfiguration?) throws -> MCPCredentials {
        guard let token = response["access_token"] as? String, !token.isEmpty,
              (response["token_type"] as? String)?.lowercased() == "bearer",
              let lifetime = response["expires_in"] as? Double, lifetime > 0 else { throw MCPServiceError.invalidMetadata }
        var result = credentials
        if let configuration, let granted = response["scope"] as? String,
           !Set(configuration.scopes).isSubset(of: Set(granted.split(separator: " ").map(String.init))) {
            throw MCPServiceError.signInRequired
        }
        result.accessToken = token
        result.refreshToken = response["refresh_token"] as? String ?? credentials.refreshToken
        result.expiresAt = Date().addingTimeInterval(lifetime)
        return result
    }
    static func nonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MCPServiceError.credentialStorage
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
