import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NoodleCore

/// IAM Identity Center's sign-in for a whole AWS organisation, as AWS's own command line does it: the app registers
/// itself as a client with the organisation's Identity Center, the person approves a code on their organisation's
/// sign-in page, and the access token that brings lists the accounts they may use and gets each one's short-lived role
/// keys. No client is made in advance, and nothing but the person's approval is asked for. Identity Center returns only
/// to a loopback address after a browser sign-in, so the code is approved instead and nothing listens on this Mac.
struct AWSIdentityCenter: Sendable {
    let configuration: @Sendable () -> URLSessionConfiguration

    /// The client registered with an organisation's Identity Center, good until `expiresAt`.
    struct Client: Codable, Equatable, Sendable {
        let id: String
        let secret: String
        let expiresAt: Date
    }

    /// A code waiting for the person's approval, and the page they approve it on.
    struct Approval: Sendable {
        let deviceCode: String
        let userCode: String
        let page: URL
        let expiresAt: Date
        let interval: Int
    }

    struct Tokens: Sendable {
        let accessToken: String
        let expiresAt: Date
        let refreshToken: String?
    }

    /// Why a token is not ready yet: the person has not approved the code, or asks are coming too often.
    enum Pending: Error { case waiting, slower }

    /// An account the sign-in covers has no role of the connection's name.
    struct RoleMissing: Error {}

    static let scope = "sso:account:access"

    /// The region an organisation's Identity Center is in, as its start page names its sign-in service.
    static func region(inStartPage page: String) -> String? {
        for part in page.components(separatedBy: "https://oidc.").dropFirst() {
            let region = part.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            guard part.dropFirst(region.count).hasPrefix(".amazonaws.com"),
                  let checked = try? ToolConnection.validatedAWSRegion(String(region)) else { continue }
            return checked
        }
        return nil
    }

    func region(of startURL: URL) async throws -> String {
        let (data, status) = try await send(URLRequest(url: startURL))
        guard status == 200, let region = Self.region(inStartPage: String(decoding: data, as: UTF8.self)) else {
            throw ToolConnectionError.message("That AWS access portal could not be read. Check its URL.")
        }
        return region
    }

    func register(region: String, startURL: URL, name: String) async throws -> Client {
        struct Body: Encodable {
            let clientName: String, clientType: String, scopes: [String], grantTypes: [String], issuerUrl: String
        }
        struct Answer: Decodable { let clientId: String; let clientSecret: String; let clientSecretExpiresAt: Double }
        let answer: Answer = try await post(oidc(region, "client/register"), Body(
            clientName: name, clientType: "public", scopes: [Self.scope],
            grantTypes: ["urn:ietf:params:oauth:grant-type:device_code", "refresh_token"], issuerUrl: startURL.absoluteString))
        return Client(id: answer.clientId, secret: answer.clientSecret, expiresAt: Date(timeIntervalSince1970: answer.clientSecretExpiresAt))
    }

    func startApproval(region: String, client: Client, startURL: URL) async throws -> Approval {
        struct Body: Encodable { let clientId: String, clientSecret: String, startUrl: String }
        struct Answer: Decodable {
            let deviceCode: String, userCode: String, verificationUri: String?, verificationUriComplete: String?
            let expiresIn: Int, interval: Int?
        }
        let answer: Answer = try await post(oidc(region, "device_authorization"),
                                            Body(clientId: client.id, clientSecret: client.secret, startUrl: startURL.absoluteString))
        guard let page = URL(string: answer.verificationUriComplete ?? answer.verificationUri ?? ""), page.scheme == "https" else {
            throw ToolConnectionServiceError.invalidMetadata
        }
        return Approval(deviceCode: answer.deviceCode, userCode: answer.userCode, page: page,
                        expiresAt: Date().addingTimeInterval(TimeInterval(answer.expiresIn)), interval: answer.interval ?? 5)
    }

    /// The tokens the person's approval brought; `Pending` while they have not approved it yet.
    func token(region: String, client: Client, approval: Approval) async throws -> Tokens {
        struct Body: Encodable { let clientId: String, clientSecret: String, grantType: String, deviceCode: String }
        return try await token(region, Body(clientId: client.id, clientSecret: client.secret,
                                            grantType: "urn:ietf:params:oauth:grant-type:device_code", deviceCode: approval.deviceCode),
                               refreshing: false)
    }

    func refresh(region: String, client: Client, refreshToken: String) async throws -> Tokens {
        struct Body: Encodable { let clientId: String, clientSecret: String, grantType: String, refreshToken: String }
        return try await token(region, Body(clientId: client.id, clientSecret: client.secret, grantType: "refresh_token",
                                            refreshToken: refreshToken), refreshing: true)
    }

    private struct TokenAnswer: Decodable { let accessToken: String; let expiresIn: Int; let refreshToken: String? }
    private struct TokenRefusal: Decodable { let error: String?; let error_description: String? }

    private func token(_ region: String, _ body: some Encodable, refreshing: Bool) async throws -> Tokens {
        var request = URLRequest(url: try oidc(region, "token"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await send(request)
        if status == 200 {
            let answer = try JSONDecoder().decode(TokenAnswer.self, from: data)
            return Tokens(accessToken: answer.accessToken, expiresAt: Date().addingTimeInterval(TimeInterval(answer.expiresIn)),
                          refreshToken: answer.refreshToken)
        }
        let refusal = try? JSONDecoder().decode(TokenRefusal.self, from: data)
        let code = refusal?.error ?? ""
        if code == "authorization_pending" { throw Pending.waiting }
        if code == "slow_down" { throw Pending.slower }
        // A refresh the service no longer takes means signing in again; a code refused or let expire, saying so.
        if refreshing, status == 400 || status == 401 { throw ToolConnectionServiceError.signInRequired }
        switch code {
        case "expired_token": throw ToolConnectionError.message("The code expired before it was approved. Connect again.")
        case "access_denied": throw ToolConnectionError.message("The sign-in was not approved.")
        case "": throw ToolConnectionServiceError.network(status)
        default: throw ToolConnectionServiceError.authorizationRefused(code: code, reason: refusal?.error_description)
        }
    }

    /// Every account the sign-in covers, a page at a time.
    func accounts(region: String, accessToken: String) async throws -> [AWSAccount] {
        struct Account: Decodable { let accountId: String; let accountName: String?; let emailAddress: String? }
        struct Answer: Decodable { let accountList: [Account]?; let nextToken: String? }
        var accounts: [AWSAccount] = [], next: String?
        for _ in 0..<50 {
            let answer: Answer = try await portal(region, "assignment/accounts", ["max_result": "100", "next_token": next], accessToken)
            accounts += (answer.accountList ?? []).map { AWSAccount(id: $0.accountId, name: $0.accountName ?? $0.accountId, email: $0.emailAddress) }
            next = answer.nextToken
            if next?.isEmpty != false { return accounts }
        }
        return accounts
    }

    /// The roles the person may take in one account.
    func roles(region: String, accessToken: String, account: String) async throws -> [String] {
        struct Role: Decodable { let roleName: String }
        struct Answer: Decodable { let roleList: [Role]?; let nextToken: String? }
        var roles: [String] = [], next: String?
        for _ in 0..<20 {
            let answer: Answer = try await portal(region, "assignment/roles",
                                                  ["account_id": account, "max_result": "100", "next_token": next], accessToken)
            roles += (answer.roleList ?? []).map(\.roleName)
            next = answer.nextToken
            if next?.isEmpty != false { return roles }
        }
        return roles
    }

    /// Short-lived keys for `role` in `account`; `RoleMissing` when the person has no such role there.
    func keys(region: String, accessToken: String, account: String, role: String) async throws -> ConnectionAWSKey {
        struct Credentials: Decodable { let accessKeyId: String; let secretAccessKey: String; let sessionToken: String?; let expiration: Double }
        struct Answer: Decodable { let roleCredentials: Credentials }
        let answer: Answer
        do {
            answer = try await portal(region, "federation/credentials", ["account_id": account, "role_name": role], accessToken)
        } catch ToolConnectionServiceError.network(403) { throw RoleMissing() }
        let credentials = answer.roleCredentials
        return ConnectionAWSKey(accessKeyID: credentials.accessKeyId, secretAccessKey: credentials.secretAccessKey,
                                sessionToken: credentials.sessionToken,
                                expiresAt: Date(timeIntervalSince1970: credentials.expiration / 1_000))
    }

    /// Ends the sign-in at Identity Center, so its tokens are no longer good anywhere.
    func logout(region: String, accessToken: String) async throws {
        var request = URLRequest(url: try host("portal.sso.\(region).amazonaws.com", "logout", [:]))
        request.httpMethod = "POST"
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        let (_, status) = try await send(request)
        guard (200..<300).contains(status) || status == 401 else { throw ToolConnectionServiceError.network(status) }
    }

    // MARK: Requests

    private func oidc(_ region: String, _ path: String) throws -> URL {
        try host("oidc.\(try ToolConnection.validatedAWSRegion(region)).amazonaws.com", path, [:])
    }

    private func host(_ host: String, _ path: String, _ query: [String: String?]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/" + path
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }.sorted { $0.name < $1.name }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw ToolConnectionServiceError.invalidMetadata }
        return url
    }

    private func post<Answer: Decodable>(_ url: URL, _ body: some Encodable) async throws -> Answer {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await send(request)
        guard status == 200 else { throw ToolConnectionServiceError.network(status) }
        return try JSONDecoder().decode(Answer.self, from: data)
    }

    private func portal<Answer: Decodable>(_ region: String, _ path: String, _ query: [String: String?], _ accessToken: String) async throws -> Answer {
        var request = URLRequest(url: try host("portal.sso.\(try ToolConnection.validatedAWSRegion(region)).amazonaws.com", path, query))
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        let (data, status) = try await send(request)
        // An access token the portal no longer takes means signing in again.
        if status == 401 { throw ToolConnectionServiceError.signInRequired }
        guard status == 200 else { throw ToolConnectionServiceError.network(status) }
        return try JSONDecoder().decode(Answer.self, from: data)
    }

    /// Only Identity Center's own hosts and the organisation's start page, over HTTPS, without following redirects.
    /// Every answer's status is read here, since a refusal says why in its body.
    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard let url = request.url, url.scheme == "https", let host = url.host?.lowercased(), url.user == nil,
              host.hasSuffix(".amazonaws.com") || host.hasSuffix(".awsapps.com") else {
            throw ToolConnectionError.message("AWS sign-in may only reach AWS.")
        }
        let configuration = configuration()
        configuration.protocolClasses = configuration.protocolClasses?.filter { $0 != MCPGuardedHTTP.self }
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request, limit: 2 * 1_048_576, tooLarge: ToolConnectionServiceError.responseTooLarge)
        guard let http = response as? HTTPURLResponse else { throw ToolConnectionServiceError.network(0) }
        return (data, http.statusCode)
    }
}
