import Foundation
import MCP
import NoodleCore

public actor MCPService {
    private let credentials: any MCPCredentialStorage
    private let oauth: MCPOAuth
    private let httpConfiguration: @Sendable () -> URLSessionConfiguration
    private var queues: [UUID: Task<Data, Error>] = [:]
    private var queueTickets: [UUID: UUID] = [:]
    private var epochs: [UUID: Int] = [:]
    private var authenticating: Set<UUID> = []
    private var serverIcons: [UUID: [Icon]] = [:]
    public init(namespace: String) {
        credentials = MCPCredentialStore(service: namespace + ".mcp.oauth")
        oauth = MCPOAuth()
        httpConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MCPGuardedHTTP.self]
            configuration.timeoutIntervalForResource = 90
            return configuration
        }
    }
    init(credentials: any MCPCredentialStorage, oauth: MCPOAuth,
         httpConfiguration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.credentials = credentials; self.oauth = oauth; self.httpConfiguration = httpConfiguration
    }
    public func hasCredentials(_ id: UUID) -> Bool {
        (try? credentials.load(id)?.accessToken) != nil
    }
    public func disconnect(_ id: UUID) throws {
        epochs[id, default: 0] += 1
        queues[id]?.cancel()
        queues[id] = nil
        serverIcons[id] = nil
        try credentials.remove(id)
    }
    public func icon(for connection: MCPConnectionRecord) async -> Data? {
        await MCPIcon.load(serverIcons[connection.id] ?? [], endpoint: connection.endpoint)
    }
    private func rememberIcons(_ icons: [Icon], id: UUID, epoch: Int) {
        if epochs[id, default: 0] == epoch { serverIcons[id] = icons }
    }
    public func signIn(_ connection: MCPConnectionRecord, redirectURI: URL,
                       progress: @Sendable (String) async -> Void = { _ in },
                       browser: @Sendable (URL) async throws -> URL) async throws {
        guard !authenticating.contains(connection.id) else { throw MCPServiceError.signInRequired }
        authenticating.insert(connection.id)
        defer { authenticating.remove(connection.id) }
        // Finish any refresh using the old grant before authorizing a replacement.
        if let previous = queues[connection.id] { _ = try? await previous.value }
        let epoch = epochs[connection.id, default: 0]
        await progress("Checking saved sign-in…")
        var stored = try credentials.load(connection.id)
        if stored?.endpoint != connection.endpoint || stored?.redirectURI != redirectURI {
            stored = nil
        }
        if stored == nil {
            stored = try await oauth.discoverAndRegister(endpoint: connection.endpoint, redirect: redirectURI,
                                                         clientName: "Noodle — " + connection.name, progress: progress)
            guard epochs[connection.id, default: 0] == epoch else { throw MCPServiceError.revoked }
            // Persist client ID BEFORE authorization; never re-register on app restart.
            try credentials.save(stored!, id: connection.id)
        }
        await progress("Complete sign-in in your browser…")
        let authorized = try await oauth.authorize(stored!, browser: browser)
        guard epochs[connection.id, default: 0] == epoch else { throw MCPServiceError.revoked }
        try credentials.save(authorized, id: connection.id)
    }

    public func perform(_ request: MCPBridgeRequest, connection: MCPConnectionRecord,
                        authorized: @escaping @Sendable () async -> Bool = { true }) async throws -> Data {
        guard !authenticating.contains(connection.id) else { throw MCPServiceError.signInRequired }
        let previous = queues[connection.id]
        let epoch = epochs[connection.id, default: 0]
        let ticket = UUID()
        let task = Task {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            guard Date() < request.expiresAt, self.epochs[connection.id, default: 0] == epoch else {
                throw MCPServiceError.revoked
            }
            guard await authorized() else { throw MCPServiceError.revoked }
            return try await self.execute(request, connection: connection, epoch: epoch, authorized: authorized)
        }
        queues[connection.id] = task
        queueTickets[connection.id] = ticket
        defer {
            if queueTickets[connection.id] == ticket {
                queues[connection.id] = nil
                queueTickets[connection.id] = nil
            }
        }
        return try await task.value
    }

    private func execute(_ request: MCPBridgeRequest, connection: MCPConnectionRecord, epoch: Int,
                         authorized: @escaping @Sendable () async -> Bool) async throws -> Data {
        guard var stored = try credentials.load(connection.id), stored.endpoint == connection.endpoint,
              stored.accessToken != nil else { throw MCPServiceError.signInRequired }
        if (stored.expiresAt ?? .distantPast) < Date().addingTimeInterval(60) {
            do {
                stored = try await oauth.refresh(stored)
                guard epochs[connection.id, default: 0] == epoch else { throw MCPServiceError.revoked }
                // Rotating refresh token and access token are committed together.
                try credentials.save(stored, id: connection.id)
            } catch MCPServiceError.signInRequired {
                guard epochs[connection.id, default: 0] == epoch else { throw MCPServiceError.revoked }
                stored.accessToken = nil; stored.refreshToken = nil; stored.expiresAt = nil
                try credentials.save(stored, id: connection.id)
                throw MCPServiceError.signInRequired
            }
        }
        guard let token = stored.accessToken else { throw MCPServiceError.signInRequired }
        let configuration = httpConfiguration()
        let transport = HTTPClientTransport(endpoint: connection.endpoint, configuration: configuration, streaming: false,
            requestModifier: { original in
                var request = original
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                return request
            })
        // A fresh protocol session per operation avoids leaking server-side session
        // context between agents sharing an account. Credentials remain per connection.
        let client = Client(name: "Noodle", version: "1.0")
        do {
            let result = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    let initialized = try await client.connect(transport: transport)
                    await self.rememberIcons(initialized.serverInfo.icons ?? [], id: connection.id, epoch: epoch)
                    let data: Data
                    switch request.action {
                    case .tools, .inspect:
                        var tools: [Tool] = []
                        var cursor: String?
                        var seen: Set<String> = []
                        repeat {
                            let page = try await client.listTools(cursor: cursor)
                            tools += page.tools
                            cursor = page.nextCursor
                            guard tools.count <= 5_000 else { throw MCPServiceError.responseTooLarge }
                            if let cursor, !seen.insert(cursor).inserted { throw MCPServiceError.invalidMetadata }
                        } while cursor != nil
                        if request.action == .inspect {
                            guard let tool = tools.first(where: { $0.name == request.tool }) else {
                                throw MCPConnectionError.message("This connection does not offer that tool. List its tools again.")
                            }
                            data = try JSONEncoder().encode(tool)
                        } else {
                            data = try JSONEncoder().encode(ListTools.Result(tools: tools))
                        }
                    case .call:
                        guard await authorized() else { throw MCPServiceError.revoked }
                        guard let name = request.tool, !name.isEmpty else { throw MCPServiceError.invalidMetadata }
                        let arguments = try JSONDecoder().decode([String: Value].self, from: request.arguments ?? Data("{}".utf8))
                        let context = try await client.send(CallTool.request(.init(name: name, arguments: arguments)))
                        data = try JSONEncoder().encode(try await context.value)
                    }
                    guard data.count <= 8 * 1_048_576 else { throw MCPServiceError.responseTooLarge }
                    return data
                }
                group.addTask {
                    let remaining = max(0, min(90, request.expiresAt.timeIntervalSinceNow))
                    try await Task.sleep(for: .seconds(remaining))
                    await client.disconnect()
                    throw MCPServiceError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await client.disconnect()
            guard epochs[connection.id, default: 0] == epoch else { throw MCPServiceError.revoked }
            return result
        } catch {
            await client.disconnect()
            // Never echo transport errors containing a provider's private response.
            if let error = error as? MCPServiceError { throw error }
            if let error = error as? MCPConnectionError { throw error }
            throw MCPConnectionError.message("The tool request failed. Check the connection in Settings → Tools. Verify remote changes before retrying.")
        }
    }
}
