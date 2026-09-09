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

    func discoverAndRegister(endpoint: URL, redirect: URL, clientName: String,
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
        guard let protectedResource,
              let resourceString = protectedResource["resource"] as? String,
              let resource = URL(string: resourceString),
              resource == endpoint,
              let issuers = protectedResource["authorization_servers"] as? [String],
              let first = issuers.first, let issuer = URL(string: first) else { throw MCPServiceError.invalidMetadata }
        _ = try MCPConnectionRecord.validatedEndpoint(issuer)
        var metadata: Object?
        await progress("Checking authorization server…")
        for candidate in discovery.authorizationServerMetadataURLs(for: issuer) {
            if let object = try? await request(candidate), object["issuer"] as? String == issuer.absoluteString {
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
        guard let registrationString = metadata["registration_endpoint"] as? String,
              let registration = URL(string: registrationString) else { throw MCPServiceError.registrationUnsupported }
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
                              resource: resource, scope: (protectedResource["scopes_supported"] as? [String])?.joined(separator: " "))
    }

    func authorize(_ credentials: MCPCredentials, browser: @Sendable (URL) async throws -> URL) async throws -> MCPCredentials {
        let verifier = try Self.nonce()
        let state = try Self.nonce()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var components = URLComponents(url: credentials.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: credentials.clientID),
            .init(name: "redirect_uri", value: credentials.redirectURI.absoluteString),
            .init(name: "resource", value: credentials.resource.absoluteString),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256")
        ]
        if let scope = credentials.scope, !scope.isEmpty { components.queryItems?.append(.init(name: "scope", value: scope)) }
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
        let response = try await request(credentials.tokenEndpoint, form: [
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "client_id": credentials.clientID, "redirect_uri": credentials.redirectURI.absoluteString,
            "resource": credentials.resource.absoluteString
        ])
        return try updated(credentials, response: response)
    }

    func refresh(_ credentials: MCPCredentials) async throws -> MCPCredentials {
        guard let refreshToken = credentials.refreshToken else { throw MCPServiceError.signInRequired }
        let response = try await request(credentials.tokenEndpoint, form: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": credentials.clientID, "resource": credentials.resource.absoluteString
        ])
        return try updated(credentials, response: response)
    }
    private func updated(_ credentials: MCPCredentials, response: Object) throws -> MCPCredentials {
        guard let token = response["access_token"] as? String, !token.isEmpty,
              (response["token_type"] as? String)?.lowercased() == "bearer",
              let lifetime = response["expires_in"] as? Double, lifetime > 0 else { throw MCPServiceError.invalidMetadata }
        var result = credentials
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
