import Foundation
import MCP
import NoodleCore

public actor MCPService {
    private let credentials: any MCPCredentialStorage
    private let oauth: MCPOAuth
    private let httpConfiguration: @Sendable () -> URLSessionConfiguration
    private var queues: [UUID: Task<Data, Error>] = [:]
    private var queueTickets: [UUID: UUID] = [:]
    private var requests: [UUID: [UUID: MCPActiveRequest]] = [:]
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
        let pending = requests.removeValue(forKey: id) ?? [:]
        for request in pending.values {
            request.completion.finish(.failure(MCPServiceError.revoked))
            request.task.cancel()
        }
        queues[id] = nil
        queueTickets[id] = nil
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
            var stored = try credentials.load(connection.id)
            if stored?.endpoint != connection.endpoint || stored?.redirectURI != redirectURI {
                stored = nil
            }
            if stored == nil {
                stored = try await oauth.discoverAndRegister(endpoint: connection.endpoint, redirect: redirectURI,
                                                             clientName: "Noodle — " + connection.name, progress: progress)
                try checkActive(connection.id, epoch: epoch)
                // Persist client ID BEFORE authorization; never re-register on app restart.
                try credentials.save(stored!, id: connection.id)
            }
            await progress("Complete sign-in in your browser…")
            try checkActive(connection.id, epoch: epoch)
            let authorized = try await oauth.authorize(stored!) { url in
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

    public func perform(_ request: MCPBridgeRequest, connection: MCPConnectionRecord,
                        authorized: @escaping @Sendable () async -> Bool = { true }) async throws -> Data {
        try Task.checkCancellation()
        guard Date() < request.expiresAt else { throw MCPServiceError.timedOut }
        guard !authenticating.contains(connection.id) else { throw MCPServiceError.signInRequired }
        let deadline = min(request.expiresAt, Date().addingTimeInterval(90))
        let previous = queues[connection.id]
        let epoch = epochs[connection.id, default: 0]
        let ticket = UUID()
        let completion = MCPRequestCompletion()
        let task = Task {
            if let previous { _ = try? await previous.value }
            try self.checkActive(connection.id, epoch: epoch, deadline: deadline)
            guard Date() < request.expiresAt else { throw MCPServiceError.timedOut }
            guard await authorized() else { throw MCPServiceError.revoked }
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
            if completion.finish(.failure(MCPServiceError.timedOut)) { task.cancel() }
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
        guard epochs[id, default: 0] == epoch else { throw MCPServiceError.revoked }
        try Task.checkCancellation()
        if let deadline, Date() >= deadline { throw MCPServiceError.timedOut }
    }

    private func execute(_ request: MCPBridgeRequest, connection: MCPConnectionRecord, epoch: Int, deadline: Date,
                         authorized: @escaping @Sendable () async -> Bool) async throws -> Data {
        guard var stored = try credentials.load(connection.id), stored.endpoint == connection.endpoint,
              stored.accessToken != nil else { throw MCPServiceError.signInRequired }
        if (stored.expiresAt ?? .distantPast) < Date().addingTimeInterval(60) {
            do {
                stored = try await oauth.refresh(stored)
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                // Rotating refresh token and access token are committed together.
                try credentials.save(stored, id: connection.id)
            } catch MCPServiceError.signInRequired {
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                stored.accessToken = nil; stored.refreshToken = nil; stored.expiresAt = nil
                try credentials.save(stored, id: connection.id)
                throw MCPServiceError.signInRequired
            }
        }
        try checkActive(connection.id, epoch: epoch, deadline: deadline)
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
            let result = try await withTaskCancellationHandler {
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                let initialized = try await client.connect(transport: transport)
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                rememberIcons(initialized.serverInfo.icons ?? [], id: connection.id, epoch: epoch)
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
                    try checkActive(connection.id, epoch: epoch, deadline: deadline)
                    guard let name = request.tool, !name.isEmpty else { throw MCPServiceError.invalidMetadata }
                    let arguments = try JSONDecoder().decode([String: Value].self, from: request.arguments ?? Data("{}".utf8))
                    let context = try await client.send(CallTool.request(.init(name: name, arguments: arguments)))
                    data = try JSONEncoder().encode(try await context.value)
                }
                try checkActive(connection.id, epoch: epoch, deadline: deadline)
                guard data.count <= 8 * 1_048_576 else { throw MCPServiceError.responseTooLarge }
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
            if let error = error as? MCPServiceError { throw error }
            if let error = error as? MCPConnectionError { throw error }
            throw MCPConnectionError.message("The tool request failed. Check the connection in Settings → Tools. Verify remote changes before retrying.")
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
