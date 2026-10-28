import Foundation
import MCP
import NoodleCore

/// Speaks MCP to one long-lived program per connection. A call does not start a second copy.
public actor MCPProgramRuntime {
    private let supervisor = MCPProgramSupervisor()
    private var clients: [UUID: Client] = [:]
    private var transports: [UUID: StdioTransport] = [:]
    private var boundProcess: [UUID: Int32] = [:]
    private let secrets: any MCPProgramSecretStorage
    private let spawner: @Sendable (MCPProgramLaunch) throws -> MCPProgramSession

    public init(secrets: any MCPProgramSecretStorage = MCPProgramMemorySecrets(),
                spawner: @escaping @Sendable (MCPProgramLaunch) throws -> MCPProgramSession = { try MCPProgramSession(launch: $0) }) {
        self.secrets = secrets
        self.spawner = spawner
    }

    public func saveSecrets(_ values: [String: String], id: UUID) throws { try secrets.save(values, id: id) }
    public func loadSecrets(_ id: UUID) throws -> [String: String] { try secrets.load(id) }
    public func remove(_ id: UUID) async throws {
        if let client = clients.removeValue(forKey: id) { await client.disconnect() }
        boundProcess[id] = nil
        await supervisor.stop(id)
        try secrets.remove(id)
    }

    public func capturedError(_ id: UUID) async -> String {
        await supervisor.standardError(id) ?? ""
    }

    public func perform(_ request: MCPBridgeRequest, program: MCPProgramRecord, root: URL, user: String,
                        authorized: @escaping @Sendable () async -> Bool) async throws -> Data {
        guard Date() < request.expiresAt else { throw MCPServiceError.timedOut }
        let executable = try MCPProgramRecord.resolveExecutable(program.executable, lookup: MCPProgramRecord.pathLookup)
        let directory = MCPProgramRecord.workingDirectory(root: root, id: program.id)
        let subject = MCPProgramRecord.subject(executable: executable, arguments: program.arguments,
                                                workingDirectory: directory, environmentNames: program.environmentNames)
        guard program.consentedSubject == subject else {
            throw MCPConnectionError.message("Approve this program in Settings → Tools before using it.")
        }
        let stored = try secrets.load(program.id)
        var environment = MCPProgramRecord.minimalEnvironment(user: user, temporaryDirectory: directory.path)
        var secretValues: [String] = []
        for name in program.environmentNames {
            let value = stored[name] ?? ""
            environment[name] = value
            if value.count >= 4 { secretValues.append(value) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let launch = MCPProgramLaunch(executable: executable, arguments: program.arguments, environment: environment,
                                       workingDirectory: directory, secrets: secretValues)
        let id = program.id
        await supervisor.prepare(id) { [spawner] in try spawner(launch) }
        let session: MCPProgramSession
        do { session = try await supervisor.start(id) }
        catch {
            throw error
        }
        await supervisor.noteUse(id, at: Date())
        let client = try await client(for: id, session: session)
        if let failure = session.protocolError() { throw MCPConnectionError.message(failure) }
        return try await exchange(request, client: client, session: session, authorized: authorized)
    }

    private func client(for id: UUID, session: MCPProgramSession) async throws -> Client {
        if boundProcess[id] == session.processIdentifier, let client = clients[id] { return client }
        if let previous = clients.removeValue(forKey: id) { await previous.disconnect() }
        transports[id] = nil
        let descriptors = session.transportDescriptors()
        let transport = StdioTransport(input: descriptors.input, output: descriptors.output)
        transports[id] = transport
        let client = Client(name: "Noodle", version: "1.0")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await client.connect(transport: transport) }
            group.addTask {
                try await Task.sleep(for: .seconds(MCPProgramRecord.startTimeoutSeconds))
                throw MCPConnectionError.message("The program did not start in time. The connection was closed.")
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                session.stop()
                if let failure = session.protocolError() { throw MCPConnectionError.message(failure) }
                throw error
            }
        }
        if let failure = session.protocolError() {
            session.stop()
            throw MCPConnectionError.message(failure)
        }
        clients[id] = client
        transports[id] = transport
        boundProcess[id] = session.processIdentifier
        return client
    }

    private func exchange(_ request: MCPBridgeRequest, client: Client, session: MCPProgramSession,
                          authorized: @escaping @Sendable () async -> Bool) async throws -> Data {
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
        case .resources:
            var resources: [Resource] = []
            var cursor: String?
            repeat {
                let page = try await client.listResources(cursor: cursor)
                resources += page.resources
                cursor = page.nextCursor
                guard resources.count <= 5_000 else { throw MCPServiceError.responseTooLarge }
            } while cursor != nil
            data = try JSONEncoder().encode(ListResources.Result(resources: resources))
        case .readResource:
            guard await authorized() else { throw MCPServiceError.revoked }
            guard let uri = request.uri, !uri.isEmpty, uri.utf8.count <= 4096 else { throw MCPServiceError.invalidMetadata }
            let context = try await client.send(ReadResource.request(.init(uri: uri)))
            data = try JSONEncoder().encode(try await context.value)
        }
        guard data.count <= MCPBridgeFiles.maxResultBytes else { throw MCPServiceError.responseTooLarge }
        if let failure = session.protocolError() { throw MCPConnectionError.message(failure) }
        return data
    }
}
