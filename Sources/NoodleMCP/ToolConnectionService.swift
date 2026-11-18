import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MCP
import NoodleCore
import ProductIdentity

public actor ToolConnectionService {
    private let credentials: any MCPCredentialStorage
    private let tokens: any ConnectionTokenStorage
    private let clients: any ConnectionClientSecretStorage
    private let awsKeys: any ConnectionAWSKeyStorage
    private let googleKeys: any ConnectionGoogleKeyStorage
    private let oauth: MCPOAuth
    private let httpConfiguration: @Sendable () -> URLSessionConfiguration
    private var queues: [UUID: Task<Data, Error>] = [:]
    private var queueTickets: [UUID: UUID] = [:]
    private var requests: [UUID: [UUID: MCPActiveRequest]] = [:]
    private var epochs: [UUID: Int] = [:]
    private var authenticating: Set<UUID> = []
    private var serverIcons: [UUID: [Icon]] = [:]
    private var adapters: [String: any ToolConnectionAdapter] = [:]
    public init(namespace: String) {
        #if canImport(Security)
        credentials = ConnectionKeychainStore<MCPCredentials>(service: namespace + ".mcp.oauth",
                                                       label: "\(ProductIdentity.current.name) MCP connection")
        tokens = ConnectionKeychainStore<ConnectionToken>(service: namespace + ".mcp.token", label: "\(ProductIdentity.current.name) MCP token")
        clients = ConnectionKeychainStore<ConnectionClientSecret>(service: namespace + ".mcp.client",
                                                    label: "\(ProductIdentity.current.name) MCP client secret")
        awsKeys = ConnectionKeychainStore<ConnectionAWSKey>(service: namespace + ".mcp.aws", label: "\(ProductIdentity.current.name) AWS access key")
        googleKeys = ConnectionKeychainStore<ConnectionGoogleKey>(service: namespace + ".mcp.google", label: "\(ProductIdentity.current.name) Google service account")
        #else
        googleKeys = NoConnectionCredentials()
        credentials = NoConnectionCredentials()
        tokens = NoConnectionCredentials()
        clients = NoConnectionCredentials()
        awsKeys = NoConnectionCredentials()
        #endif
        oauth = MCPOAuth()
        httpConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MCPGuardedHTTP.self]
            configuration.timeoutIntervalForResource = 90
            return configuration
        }
    }
    init(credentials: any MCPCredentialStorage, tokens: any ConnectionTokenStorage = MemoryConnectionTokens(),
         clients: any ConnectionClientSecretStorage = MemoryConnectionClientSecrets(), awsKeys: any ConnectionAWSKeyStorage = MemoryConnectionAWSKeys(),
         googleKeys: any ConnectionGoogleKeyStorage = MemoryConnectionGoogleKeys(),
         oauth: MCPOAuth, httpConfiguration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.credentials = credentials; self.tokens = tokens; self.clients = clients; self.awsKeys = awsKeys; self.googleKeys = googleKeys
        self.oauth = oauth; self.httpConfiguration = httpConfiguration
    }
    /// The adapters this app serves connections with, by the name connections give.
    public func useAdapters(_ adapters: [String: any ToolConnectionAdapter]) {
        self.adapters = adapters
    }

    public func hasCredentials(_ id: UUID) -> Bool {
        if (try? tokens.load(id)) != nil || (try? clients.load(id)) != nil || (try? awsKeys.load(id)) != nil
            || (try? googleKeys.load(id)) != nil { return true }
        guard let stored = try? credentials.load(id), stored.accessToken != nil else { return false }
        return (try? oauth.validateConfiguration(stored, configuration: Self.oauthConfiguration(for: stored.endpoint, clientID: stored.clientID))) != nil
    }
    /// What asking the service to revoke a connection's sign-in or key came to.
    public enum Revocation: Equatable, Sendable {
        /// The service revoked it, or no longer knew it.
        case revoked
        /// The service offers no way to revoke it through its API; it is only forgotten here.
        case notOffered
        /// The service could not be asked, or refused; it is still forgotten here.
        case failed(String)
    }

    /// Asks the service to revoke what this connection signed in with or was given: an OAuth sign-in at its
    /// revocation endpoint, or a key its catalogue entry says how to revoke. Nothing is forgotten here.
    public func revoke(_ connection: ToolConnection) async -> Revocation {
        if let stored = try? credentials.load(connection.id), stored.endpoint == connection.endpoint,
           stored.refreshToken != nil || stored.accessToken != nil {
            let field = Self.connectionConfiguration(for: connection.endpoint)?.oauthClientField
            let configured = Self.oauthConfiguration(for: connection.endpoint, clientID: field.flatMap { connection.settings?[$0] })
            guard let endpoint = stored.revocationEndpoint ?? configured?.revocationEndpoint else { return .notOffered }
            do { try await oauth.revoke(stored, at: endpoint); return .revoked }
            catch { return .failed(Self.revocationFailure(error)) }
        }
        guard let revocation = ToolCatalog.definition(for: connection).flatMap({ tool -> TokenRevocation? in
            if case .connection(let configuration) = tool.configuration { return configuration.tokenRevocation }
            return nil
        }), connection.usesToken, let token = try? tokens.load(connection.id), token.endpoint == connection.endpoint else {
            return .notOffered
        }
        do {
            var address = connection.endpoint
            if revocation.path.hasPrefix("/") {
                var root = URLComponents(url: connection.endpoint, resolvingAgainstBaseURL: false)
                root?.path = revocation.path; root?.query = nil
                guard let url = root?.url else { return .notOffered }
                address = url
            } else {
                address = revocation.path.split(separator: "/").reduce(address) { $0.appendingPathComponent(String($1)) }
            }
            var request = URLRequest(url: address)
            request.httpMethod = revocation.method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body = revocation.body {
                // The key goes in as a JSON string, so whatever it holds stays inside its quotes.
                let quoted = String(decoding: try JSONEncoder().encode(token.value), as: UTF8.self)
                request.httpBody = Data(body.replacingOccurrences(of: "\"{token}\"", with: quoted).utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let authorization: ConnectionAuthorization? = revocation.authorized
                ? try await self.authorization(for: connection, epoch: epochs[connection.id, default: 0], deadline: Date().addingTimeInterval(30))
                : nil
            let access = ToolConnectionAccess(endpoint: connection.endpoint, authorization: authorization, configuration: httpConfiguration)
            let (_, response) = try await access.data(for: request)
            // A key the service no longer accepts is as good as revoked.
            return (200..<300).contains(response.statusCode) || response.statusCode == 401 ? .revoked
                : .failed("The service answered \(response.statusCode).")
        } catch { return .failed(Self.revocationFailure(error)) }
    }

    /// Revokes what the connection holds at the service where it can, then forgets it here whatever the service said.
    public func signOut(_ connection: ToolConnection) async -> Revocation {
        let result = await revoke(connection)
        try? disconnect(connection.id)
        return result
    }

    private nonisolated static func revocationFailure(_ error: Error) -> String {
        error is ToolConnectionServiceError || error is ToolConnectionError ? error.localizedDescription : "The service could not be reached."
    }

    public func disconnect(_ id: UUID) throws {
        epochs[id, default: 0] += 1
        let pending = requests.removeValue(forKey: id) ?? [:]
        for request in pending.values {
            request.completion.finish(.failure(ToolConnectionServiceError.revoked))
            request.task.cancel()
        }
        queues[id] = nil
        queueTickets[id] = nil
        serverIcons[id] = nil
        try credentials.remove(id)
        try tokens.remove(id)
        try clients.remove(id)
        try awsKeys.remove(id)
        try googleKeys.remove(id)
    }

    /// Keeps a Google service account's key, from the JSON file Google issues, in place of signing in. The key is
    /// checked by signing with it before it is kept.
    public func saveGoogleKey(_ json: String, for connection: ToolConnection) throws {
        guard Organisation.allows(Organisation.action(for: connection)) else { throw ToolConnectionServiceError.notAllowed }
        guard connection.googleServiceAccount != nil else {
            throw ToolConnectionError.message("This connection does not act as a Google service account.")
        }
        struct File: Decodable { let type: String?; let client_email: String?; let private_key: String?; let private_key_id: String? }
        guard json.utf8.count <= 16_384, let file = try? JSONDecoder().decode(File.self, from: Data(json.utf8)),
              file.type == "service_account", let email = file.client_email, email.contains("@"), let pem = file.private_key else {
            throw ToolConnectionError.message("Paste the JSON key of a Google service account.")
        }
        try GoogleAssertion.validate(pem)
        try googleKeys.save(ConnectionGoogleKey(endpoint: connection.endpoint, clientEmail: email, privateKeyID: file.private_key_id,
                                         privateKey: pem), id: connection.id)
    }

    /// Keeps the AWS access key a connection signs its requests with, in place of signing in.
    public func saveAWSKey(accessKeyID: String, secretAccessKey: String, sessionToken: String?, for connection: ToolConnection) throws {
        guard Organisation.allows(Organisation.action(for: connection)) else { throw ToolConnectionServiceError.notAllowed }
        guard connection.awsSigning != nil else { throw ToolConnectionError.message("This connection does not sign with an AWS key.") }
        func line(_ value: String, _ name: String) throws -> String {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 4_096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ToolConnectionError.message("Paste the \(name) on one line.")
            }
            return value
        }
        let token = try sessionToken.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try line($0, "session token") }
        try awsKeys.save(ConnectionAWSKey(endpoint: connection.endpoint, accessKeyID: try line(accessKeyID, "access key ID"),
                                   secretAccessKey: try line(secretAccessKey, "secret access key"), sessionToken: token), id: connection.id)
    }

    /// Keeps the client ID and secret a connection exchanges for access tokens, in place of signing in.
    /// A new pair starts afresh: no token got with the old one is used again.
    public func saveClientCredentials(clientID: String, secret: String, for connection: ToolConnection) throws {
        guard Organisation.allows(Organisation.action(for: connection)) else { throw ToolConnectionServiceError.notAllowed }
        guard let exchange = connection.clientCredentials else {
            throw ToolConnectionError.message("This connection does not use a client ID and secret.")
        }
        func line(_ value: String, _ name: String) throws -> String {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 4_096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ToolConnectionError.message("Paste the \(name) on one line.")
            }
            return value
        }
        try clients.save(ConnectionClientSecret(endpoint: connection.endpoint, tokenEndpoint: exchange.tokenEndpoint,
                                         clientID: line(clientID, "client ID"), clientSecret: line(secret, "client secret")),
                         id: connection.id)
    }

    /// Keeps the token a token connection sends, in place of signing in. Surrounding spaces are
    /// dropped; a token is one line, since it goes in a request header.
    public func saveToken(_ token: String, for connection: ToolConnection) throws {
        guard Organisation.allows(Organisation.action(for: connection)) else { throw ToolConnectionServiceError.notAllowed }
        guard connection.usesToken else {
            throw ToolConnectionError.message("This connection signs in through the browser, not with a token.")
        }
        let header = connection.tokenHeader ?? connection.tokenParameter ?? ""
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 8_192, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ToolConnectionError.message("Paste the token on one line.")
        }
        try tokens.save(ConnectionToken(endpoint: connection.endpoint, header: header, value: value), id: connection.id)
    }
    public func icon(for connection: ToolConnection) async -> Data? {
        await MCPIcon.load(serverIcons[connection.id] ?? [], endpoint: connection.endpoint)
    }
    public nonisolated static func configuredRedirectURI(for endpoint: URL,
                                                         bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL? {
        guard let configuration = connectionConfiguration(for: endpoint), let oauth = configuration.oauth else { return nil }
        if configuration.oauthClientField != nil { return bundleIdentifier.flatMap(accountClientRedirect) }
        return oauth.clients.first { $0.bundleIdentifier == bundleIdentifier }?.redirectURI
    }
    /// Where an organisation's own client returns: the app's bundle ID as a URL scheme.
    private nonisolated static func accountClientRedirect(_ bundleIdentifier: String) -> URL? {
        URL(string: bundleIdentifier + ":/oauth2callback")
    }
    /// Whether the connection signs in through the browser: an MCP server's that keeps no key, or one the app's
    /// adapter answers whose catalogue entry names how to sign in, as Google's do.
    public nonisolated static func signsInThroughBrowser(_ connection: ToolConnection) -> Bool {
        !connection.keepsSecret && (connection.adapter == nil || oauthConfiguration(for: connection.endpoint) != nil)
    }
    private nonisolated static func connectionConfiguration(for endpoint: URL) -> ToolConnectionConfiguration? {
        guard case .connection(let configuration)? = ToolCatalog.definition(forMCPEndpoint: endpoint)?.configuration else { return nil }
        return configuration
    }
    /// How a connection at `endpoint` signs in. For an entry whose accounts bring their organisation's own client,
    /// it is that client, `clientID`, returning to this app's bundle ID.
    private nonisolated static func oauthConfiguration(for endpoint: URL, clientID: String? = nil,
                                                       bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> MCPOAuthConfiguration? {
        guard let configuration = connectionConfiguration(for: endpoint), let oauth = configuration.oauth else { return nil }
        guard configuration.oauthClientField != nil else { return oauth }
        guard let clientID, let bundleIdentifier, let redirect = accountClientRedirect(bundleIdentifier) else { return oauth.with(clients: []) }
        return oauth.with(clients: [MCPOAuthClientConfiguration(id: clientID, bundleIdentifier: bundleIdentifier, redirectURI: redirect)])
    }
    private nonisolated static func oauthConfiguration(for connection: ToolConnection) -> MCPOAuthConfiguration? {
        let field = connectionConfiguration(for: connection.endpoint)?.oauthClientField
        return oauthConfiguration(for: connection.endpoint, clientID: field.flatMap { connection.settings?[$0] })
    }
    private nonisolated static func authorizationServer(for endpoint: URL) -> URL? {
        guard case .connection(let configuration)? = ToolCatalog.definition(forMCPEndpoint: endpoint)?.configuration else { return nil }
        return configuration.authorizationServer
    }
    private func rememberIcons(_ icons: [Icon], id: UUID, epoch: Int) {
        if epochs[id, default: 0] == epoch { serverIcons[id] = icons }
    }
    public func signIn(_ connection: ToolConnection, redirectURI: URL,
                       progress: @Sendable (String) async -> Void = { _ in },
                       browser: @Sendable (URL) async throws -> URL) async throws {
        guard Organisation.allows(Organisation.action(for: connection)) else { throw ToolConnectionServiceError.notAllowed }
        guard Self.signsInThroughBrowser(connection) else {
            throw ToolConnectionError.message("This connection does not sign in through the browser. Enter its details in its settings.")
        }
        // One that used a token or a client secret before signs in now; they would otherwise still count as its sign-in.
        try tokens.remove(connection.id)
        try clients.remove(connection.id)
        try awsKeys.remove(connection.id)
        try googleKeys.remove(connection.id)
        guard !authenticating.contains(connection.id) else { throw ToolConnectionServiceError.signInRequired }
        try Task.checkCancellation()
        authenticating.insert(connection.id)
        defer { authenticating.remove(connection.id) }
        let epoch = epochs[connection.id, default: 0]
        do {
            // Finish any refresh using the old grant before authorizing a replacement.
            if let previous = queues[connection.id] {
                await progress("Waiting for existing requests…")
                try checkActive(connection.id, epoch: epoch)
                let waiting = MCPRequestCompletion()
                Task { waiting.finish(await previous.result) }
                await withTaskCancellationHandler {
                    _ = try? await waiting.value
                } onCancel: {
                    // Stop waiting without cancelling another caller's request.
                    waiting.finish(.failure(CancellationError()))
                }
            }
            try checkActive(connection.id, epoch: epoch)
            await progress("Checking saved sign-in…")
            try checkActive(connection.id, epoch: epoch)
            let configuration = Self.oauthConfiguration(for: connection)
            var stored = try MCPOAuth.preconfiguredCredentials(endpoint: connection.endpoint, redirect: redirectURI, configuration: configuration)
                ?? credentials.load(connection.id)
            if stored?.endpoint != connection.endpoint || stored?.redirectURI != redirectURI {
                stored = nil
            }
            if stored == nil {
                stored = try await oauth.discoverAndRegister(endpoint: connection.endpoint, redirect: redirectURI,
                                                             clientName: "\(ProductIdentity.current.name) — " + connection.name,
                                                             authorizationServer: Self.authorizationServer(for: connection.endpoint),
                                                             progress: progress)
                try checkActive(connection.id, epoch: epoch)
                // Persist client ID BEFORE authorization; never re-register on app restart.
                try credentials.save(stored!, id: connection.id)
            }
            await progress("Complete sign-in in your browser…")
            try checkActive(connection.id, epoch: epoch)
            let authorized = try await oauth.authorize(stored!, configuration: configuration) { url in
                try await self.checkActive(connection.id, epoch: epoch)
                let callback = try await browser(url)
                try await self.checkActive(connection.id, epoch: epoch)
                return callback
            }
            try checkActive(connection.id, epoch: epoch)
            try credentials.save(authorized, id: connection.id)
        } catch {
            // Preserve cancellation/revocation even when URLSession reports its own error.
            try checkActive(connection.id, epoch: epoch)
            throw error
        }
    }

    public func perform(_ request: MCPBridgeRequest, connection: ToolConnection,
                        authorized: @escaping @Sendable () async -> Bool = { true }) async throws -> Data {
        // Every call asks, so a connection the organisation blocks stops at once, whoever calls.
        guard Organisation.allows(Organisation.action(for: connection)) else { throw ToolConnectionServiceError.notAllowed }
        try Task.checkCancellation()
        guard Date() < request.expiresAt else { throw ToolConnectionServiceError.timedOut }
        guard !authenticating.contains(connection.id) else { throw ToolConnectionServiceError.signInRequired }
        let deadline = min(request.expiresAt, Date().addingTimeInterval(90))
        let previous = queues[connection.id]
        let epoch = epochs[connection.id, default: 0]
        let ticket = UUID()
        let completion = MCPRequestCompletion()
        let task = Task {
            if let previous { _ = try? await previous.value }
            try self.checkActive(connection.id, epoch: epoch, deadline: deadline)
            guard Date() < request.expiresAt else { throw ToolConnectionServiceError.timedOut }
            guard await authorized() else { throw ToolConnectionServiceError.revoked }
            try self.checkActive(connection.id, epoch: epoch, deadline: deadline)
            return try await self.execute(request, connection: connection, epoch: epoch, deadline: deadline, authorized: authorized)
        }
        queues[connection.id] = task
        queueTickets[connection.id] = ticket
        requests[connection.id, default: [:]][ticket] = MCPActiveRequest(task: task, completion: completion)
        // The caller's deadline includes queueing, permission checks and token refresh.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            if completion.finish(.failure(ToolConnectionServiceError.timedOut)) { task.cancel() }
        }
        Task {
            let result = await task.result
            timeout.cancel()
            completion.finish(result)
            requests[connection.id]?[ticket] = nil
            if requests[connection.id]?.isEmpty == true { requests[connection.id] = nil }
            // Keep the queue barrier until work has actually unwound. A cancelled
            // queued caller must not let a later call overtake the active request.
            if queueTickets[connection.id] == ticket {
                queues[connection.id] = nil
                queueTickets[connection.id] = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await completion.value
        } onCancel: {
            timeout.cancel()
            if completion.finish(.failure(CancellationError())) { task.cancel() }
        }
    }

    private func checkActive(_ id: UUID, epoch: Int, deadline: Date? = nil) throws {
        guard epochs[id, default: 0] == epoch else { throw ToolConnectionServiceError.revoked }
        try Task.checkCancellation()
        if let deadline, Date() >= deadline { throw ToolConnectionServiceError.timedOut }
    }

    /// The header that proves who the connection is: its token as saved, or an OAuth access token,
    /// renewed first when it is about to expire.
    private func authorization(for connection: ToolConnection, epoch: Int, deadline: Date) async throws -> ConnectionAuthorization {
        if let signing = connection.awsSigning {
            guard let key = try awsKeys.load(connection.id), key.endpoint == connection.endpoint else { throw ToolConnectionServiceError.signInRequired }
            return .aws(key, defaultRegion: signing.region)
        }
        if let account = connection.googleServiceAccount {
            guard var key = try googleKeys.load(connection.id), key.endpoint == connection.endpoint else { throw ToolConnectionServiceError.signInRequired }
            if key.accessToken == nil || (key.expiresAt ?? .distantPast) < Date().addingTimeInterval(60) {
                let assertion = try GoogleAssertion.make(key, scopes: account.scopes, subject: account.subject)
                let response = try await oauth.request(GoogleAssertion.tokenEndpoint, form: [
                    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion,
                ])
                guard let token = response["access_token"] as? String, !token.isEmpty else { throw ToolConnectionServiceError.invalidMetadata }
                key.accessToken = token
                key.expiresAt = Date().addingTimeInterval((response["expires_in"] as? Double) ?? 3_000)
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                try googleKeys.save(key, id: connection.id)
            }
            guard let token = key.accessToken else { throw ToolConnectionServiceError.signInRequired }
            return .google(token)
        }
        if let parameter = connection.tokenParameter {
            guard let token = try tokens.load(connection.id), token.endpoint == connection.endpoint,
                  token.header == parameter else { throw ToolConnectionServiceError.signInRequired }
            return .parameter(parameter, token.value)
        }
        if let header = connection.tokenHeader {
            guard let token = try tokens.load(connection.id), token.endpoint == connection.endpoint,
                  token.header == header else { throw ToolConnectionServiceError.signInRequired }
            // The connection's scheme goes first. Otherwise a bare token in Authorization is a bearer token, and
            // one that names its own scheme goes as it is.
            let value = if let scheme = connection.tokenScheme { scheme + " " + token.value }
                else if header.caseInsensitiveCompare("Authorization") == .orderedSame && !token.value.contains(" ") { "Bearer " + token.value }
                else { token.value }
            return .header(header, value)
        }
        if let exchange = connection.clientCredentials {
            guard var secret = try clients.load(connection.id), secret.endpoint == connection.endpoint,
                  secret.tokenEndpoint == exchange.tokenEndpoint else { throw ToolConnectionServiceError.signInRequired }
            if secret.accessToken == nil || (secret.expiresAt ?? .distantPast) < Date().addingTimeInterval(60) {
                secret = try await oauth.clientToken(secret, scope: exchange.scope, parameters: exchange.parameters)
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                try clients.save(secret, id: connection.id)
            }
            guard let token = secret.accessToken else { throw ToolConnectionServiceError.signInRequired }
            return .header("Authorization", "Bearer " + token)
        }
        guard var stored = try credentials.load(connection.id), stored.endpoint == connection.endpoint,
              stored.accessToken != nil else { throw ToolConnectionServiceError.signInRequired }
        let oauthConfiguration = Self.oauthConfiguration(for: connection)
        try oauth.validateConfiguration(stored, configuration: oauthConfiguration)
        if (stored.expiresAt ?? .distantPast) < Date().addingTimeInterval(60) {
            do {
                stored = try await oauth.refresh(stored, configuration: oauthConfiguration)
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                // Rotating refresh token and access token are committed together.
                try credentials.save(stored, id: connection.id)
            } catch ToolConnectionServiceError.signInRequired {
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                stored.accessToken = nil; stored.refreshToken = nil; stored.expiresAt = nil
                try credentials.save(stored, id: connection.id)
                throw ToolConnectionServiceError.signInRequired
            }
        }
        try checkActive(connection.id, epoch: epoch, deadline: deadline)
        guard let token = stored.accessToken else { throw ToolConnectionServiceError.signInRequired }
        return .header("Authorization", "Bearer " + token)
    }

    /// A connection the app's adapter answers: its tools and calls come from the adapter, which reaches the
    /// service with the connection's credentials, if it has any.
    private func adapt(_ request: MCPBridgeRequest, adapter name: String, connection: ToolConnection, epoch: Int,
                       deadline: Date, authorized: @escaping @Sendable () async -> Bool) async throws -> Data {
        guard let adapter = adapters[name] else {
            throw ToolConnectionError.message("\(ProductIdentity.current.name) cannot serve this connection.")
        }
        let credentials = connection.keepsSecret || Self.signsInThroughBrowser(connection)
        let authorization = credentials ? try await authorization(for: connection, epoch: epoch, deadline: deadline) : nil
        try checkActive(connection.id, epoch: epoch, deadline: deadline)
        switch request.action {
        case .tools:
            let data = try await adapter.tools(for: connection)
            _ = try JSONDecoder().decode(ListTools.Result.self, from: data)
            return data
        case .inspect:
            let tools = try JSONDecoder().decode(ListTools.Result.self, from: try await adapter.tools(for: connection)).tools
            guard let tool = tools.first(where: { $0.name == request.tool }) else {
                throw ToolConnectionError.message("This connection does not offer that tool. List its tools again.")
            }
            return try JSONEncoder().encode(tool)
        case .call:
            guard await authorized() else { throw ToolConnectionServiceError.revoked }
            try checkActive(connection.id, epoch: epoch, deadline: deadline)
            guard let tool = request.tool, !tool.isEmpty else { throw ToolConnectionServiceError.invalidMetadata }
            let access = ToolConnectionAccess(endpoint: connection.endpoint, authorization: authorization, configuration: httpConfiguration)
            return try await adapter.call(tool, arguments: request.arguments ?? Data("{}".utf8), connection: connection, access: access)
        case .resources:
            return Data(#"{"resources":[]}"#.utf8)
        case .readResource:
            throw ToolConnectionError.message("This connection offers no resources.")
        }
    }

    private func execute(_ request: MCPBridgeRequest, connection: ToolConnection, epoch: Int, deadline: Date,
                         authorized: @escaping @Sendable () async -> Bool) async throws -> Data {
        if let name = connection.adapter {
            return try await adapt(request, adapter: name, connection: connection, epoch: epoch, deadline: deadline, authorized: authorized)
        }
        let authorization = try await authorization(for: connection, epoch: epoch, deadline: deadline)
        let configuration = httpConfiguration()
        let transport = HTTPClientTransport(endpoint: connection.endpoint, configuration: configuration, streaming: false,
            requestModifier: { original in
                var request = original
                authorization.apply(to: &request)
                return request
            })
        // A fresh protocol session per operation avoids leaking server-side session
        // context between agents sharing an account. Credentials remain per connection.
        let client = Client(name: "Noodle", version: "1.0")
        var initialized = false
        do {
            let result = try await withTaskCancellationHandler {
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                let initialization = try await client.connect(transport: transport)
                initialized = true
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                rememberIcons(initialization.serverInfo.icons ?? [], id: connection.id, epoch: epoch)
                let data: Data
                switch request.action {
                case .tools, .inspect:
                    var tools: [Tool] = []
                    var cursor: String?
                    var seen: Set<String> = []
                    repeat {
                        try checkActive(connection.id, epoch: epoch, deadline: deadline)
                        let page = try await client.listTools(cursor: cursor)
                        tools += page.tools
                        cursor = page.nextCursor
                        guard tools.count <= 5_000 else { throw ToolConnectionServiceError.responseTooLarge }
                        if let cursor, !seen.insert(cursor).inserted { throw ToolConnectionServiceError.invalidMetadata }
                    } while cursor != nil
                    if request.action == .inspect {
                        guard let tool = tools.first(where: { $0.name == request.tool }) else {
                            throw ToolConnectionError.message("This connection does not offer that tool. List its tools again.")
                        }
                        data = try JSONEncoder().encode(tool)
                    } else {
                        data = try JSONEncoder().encode(ListTools.Result(tools: tools))
                    }
                case .call:
                    guard await authorized() else { throw ToolConnectionServiceError.revoked }
                    try checkActive(connection.id, epoch: epoch, deadline: deadline)
                    guard let name = request.tool, !name.isEmpty else { throw ToolConnectionServiceError.invalidMetadata }
                    let arguments = try JSONDecoder().decode([String: Value].self, from: request.arguments ?? Data("{}".utf8))
                    let context = try await client.send(CallTool.request(.init(name: name, arguments: arguments)))
                    data = try JSONEncoder().encode(try await context.value)
                case .resources:
                    var resources: [Resource] = []
                    var cursor: String?
                    var seen: Set<String> = []
                    repeat {
                        try checkActive(connection.id, epoch: epoch, deadline: deadline)
                        let page = try await client.listResources(cursor: cursor)
                        resources += page.resources
                        cursor = page.nextCursor
                        guard resources.count <= 5_000 else { throw ToolConnectionServiceError.responseTooLarge }
                        if let cursor, !seen.insert(cursor).inserted { throw ToolConnectionServiceError.invalidMetadata }
                    } while cursor != nil
                    data = try JSONEncoder().encode(ListResources.Result(resources: resources))
                case .readResource:
                    guard await authorized() else { throw ToolConnectionServiceError.revoked }
                    try checkActive(connection.id, epoch: epoch, deadline: deadline)
                    guard let uri = request.uri, !uri.isEmpty, uri.utf8.count <= 4096 else {
                        throw ToolConnectionServiceError.invalidMetadata
                    }
                    let context = try await client.send(ReadResource.request(.init(uri: uri)))
                    data = try JSONEncoder().encode(try await context.value)
                }
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                guard data.count <= MCPBridgeFiles.maxResultBytes else { throw ToolConnectionServiceError.responseTooLarge }
                return data
            } onCancel: {
                // The SDK owns unstructured request tasks; cancelling our task
                // alone does not resume those requests or close their transport.
                Task { await client.disconnect() }
            }
            await client.disconnect()
            try checkActive(connection.id, epoch: epoch, deadline: deadline)
            return result
        } catch {
            await client.disconnect()
            try checkActive(connection.id, epoch: epoch, deadline: deadline)
            // Never echo transport errors containing a provider's private response.
            if let error = error as? ToolConnectionServiceError { throw error }
            if let error = error as? ToolConnectionError { throw error }
            let underlying: Error
            if case MCPError.transportError(let cause) = error { underlying = cause }
            else { underlying = error }
            let http = underlying as NSError
            if http.domain == MCPHTTPError.errorDomain { throw ToolConnectionServiceError.network(http.code) }
            let message: String
            if !initialized { message = "The MCP server could not start a connection. Try connecting again." }
            else if request.action == .call {
                message = "The tool request failed. Check whether the remote action completed before retrying."
            } else {
                message = "The MCP server could not return the requested tools or resources. Try again."
            }
            throw ToolConnectionError.message(message)
        }
    }
}

private struct MCPActiveRequest {
    let task: Task<Data, Error>
    let completion: MCPRequestCompletion
}

/// Resolves a caller once, even if cancellation, deadline and a late result race.
/// Work retains its queue position independently until transport cleanup finishes.
private final class MCPRequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?
    var value: Data {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<Data, Error>? = lock.withLock {
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }
    }
    @discardableResult
    func finish(_ result: Result<Data, Error>) -> Bool {
        let (won, pending) = lock.withLock {
            guard self.result == nil else { return (false, nil as CheckedContinuation<Data, Error>?) }
            self.result = result
            defer { continuation = nil }
            return (true, continuation)
        }
        pending?.resume(with: result)
        return won
    }
}
