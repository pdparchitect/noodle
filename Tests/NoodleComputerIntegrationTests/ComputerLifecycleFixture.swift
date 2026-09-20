import ComputerBridge
import Foundation
import NoodleComputerTools
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class ComputerResponseGate {
    private var continuation: CheckedContinuation<ComputerResponse, Error>?
    func wait() async throws -> ComputerResponse { try await withCheckedThrowingContinuation { continuation = $0 } }
    func finish(_ result: Result<ComputerResponse, Error>) { continuation?.resume(with: result); continuation = nil }
}

@MainActor final class LifecycleComputerProvider {
    let computer = RemoteComputer(id: UUID(), name: "Fixture desktop", kind: "Shell", state: "Running", symbol: "terminal")
    let terminal = UUID()
    var requests: [ComputerRequest] = []
    var blockedOperation: ComputerOperation?
    var blockedListNumber: Int?
    var blocked: ComputerResponseGate?
    var gates: [ComputerResponseGate] = []
    var errorOperation: ComputerOperation?
    var catalogue: [RemoteComputer]?
    var responses: [ComputerOperation: ComputerResponse] = [:]
    func count(_ operation: ComputerOperation) -> Int { requests.filter { $0.operation == operation }.count }
    func respond(_ request: ComputerRequest) async throws -> ComputerResponse {
        requests.append(request)
        if blockedOperation == request.operation || (request.operation == .list && count(.list) == blockedListNumber) {
            blockedOperation = nil
            blockedListNumber = nil
            let gate = ComputerResponseGate(); gates.append(gate); blocked = gate
            return try await gate.wait()
        }
        if errorOperation == request.operation { throw ComputerBridgeError("Connection lost after dispatch") }
        return response(request.operation)
    }
    func response(_ operation: ComputerOperation) -> ComputerResponse {
        if let response = responses[operation] { return response }
        if operation == .list {
            var response = ComputerResponse(computers: catalogue ?? [computer]); response.capabilities = ComputerCapabilities(); return response
        }
        var response = ComputerResponse(terminalID: terminal, data: Data("private terminal output".utf8))
        response.computerID = computer.id
        return response
    }
    func cleanUp() { gates.forEach { $0.finish(.failure(CancellationError())) } }
}

@MainActor final class ComputerLifecycleFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-computer-lifecycle-\(UUID())").resolvingSymlinksInPath()
    let repository: WorkspaceRepository
    let a: AgentRecord
    let b: AgentRecord
    let provider = LifecycleComputerProvider()
    let controller: ComputerController
    /// The same pieces the app wires together: the controller publishes assignments, the
    /// broker enforces them, and the provider forwards to the (fake) companion.
    let assignments = ToolAssignmentStore()
    let registry = ToolProviderRegistry()
    private(set) var host = ToolHostServices.none
    init() throws {
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        a = try repository.createAgent(named: "Computer A").agent
        b = try repository.createAgent(named: "Computer B").agent
        let providerRoot = root.appendingPathComponent("provider")
        try FileManager.default.createDirectory(at: providerRoot, withIntermediateDirectories: false)
        let provider = provider
        controller = ComputerController(repository: repository, socket: providerRoot.appendingPathComponent("fixture.sock"),
            applicationLookup: { nil }, connection: { try await provider.respond($0) })
        try registry.register(ComputerToolProvider(stagingRoot: { providerRoot }) { try await provider.respond($0) })
        let assignments = assignments, controller = controller
        controller.onAssignmentsChange = { assignments.replace("computer", with: $0) }
        host = .repository(repository, revoked: { kind, id, agent in
            guard kind == "computer", let computer = UUID(uuidString: id) else { return }
            Task { @MainActor in controller.revoke(computer: computer, agent: agent) }
        }) { assignments.assignments(for: $0) }
    }
    func prepare() async throws {
        await controller.refresh()
        try controller.assign([provider.computer.id], to: a)
        controller.start(agents: [a, b], monitoring: false)
    }
    var card: ComputerCard { .init(computer: provider.computer, agentID: a.id, terminalID: provider.terminal, terminalPreview: "") }
    func request(_ operation: ComputerOperation) -> ComputerRequest {
        var request = ComputerRequest(operation, computerID: provider.computer.id, agentID: a.id, terminalID: provider.terminal)
        if operation == .terminalWrite { request.data = Data("fixture command\n".utf8) }
        return request
    }
    /// Sends what a bot's `messenger tool computer ...` call becomes, and records the outcome
    /// where the old mailbox response used to appear.
    func send(_ request: ComputerRequest, agent: AgentRecord? = nil, localPath: String? = nil) throws -> URL {
        let agent = agent ?? a
        let names: [ComputerOperation: String] = [.list: "list", .start: "start", .terminalOpen: "open", .terminalRead: "read",
            .terminalWrite: "write", .terminalResize: "resize", .terminalClose: "close", .preview: "present", .fileUpload: "upload", .fileDownload: "download"]
        var arguments: [String: Any] = [:]
        arguments["computer"] = request.computerID?.uuidString
        if !request.operation.isFileTransfer { arguments["terminal"] = request.terminalID?.uuidString }
        // A forged owner in the arguments must be ignored; the broker's context names the bot.
        arguments["agentID"] = request.agentID?.uuidString
        if request.operation == .terminalWrite { arguments["base64"] = request.data?.base64EncodedString() }
        if request.operation.isFileTransfer {
            arguments[request.operation == .fileUpload ? "destination" : "source"] = request.path
            arguments[request.operation == .fileUpload ? "source" : "destination"] = localPath
        }
        let output = root.appendingPathComponent("responses/\(UUID().uuidString).response")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let call = ToolBridgeRequest(session: "fixture", action: .call, provider: "computer", tool: names[request.operation],
                                     arguments: try JSONSerialization.data(withJSONObject: arguments))
        let registry = registry, assignments = assignments, host = host
        let context = ToolCallContext(agentID: agent.id, workspace: repository.directory(for: agent))
        Task.detached {
            var response = ComputerResponse()
            do {
                let data = try await ToolBroker.perform(call, registry: registry, assignments: { assignments.assignments(for: agent.id) }, context: context, host: host)
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                if result["isError"] as? Bool == true {
                    response.error = ((result["content"] as? [[String: Any]])?.first)?["text"] as? String ?? "Tool error"
                } else if var structured = result["structuredContent"] as? [String: Any] {
                    if let text = structured.removeValue(forKey: "text") as? String { structured["data"] = Data(text.utf8).base64EncodedString() }
                    structured["localPath"] = nil
                    structured["version"] = 1 // Bots never see the protocol version; the response type requires it.
                    response = try JSONDecoder().decode(ComputerResponse.self, from: JSONSerialization.data(withJSONObject: structured))
                }
            } catch { response.error = error.localizedDescription }
            try? JSONEncoder().encode(response).write(to: output, options: .atomic)
        }
        return output
    }
    func response(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async throws -> ComputerResponse {
        try await wait(file: file, line: line) { FileManager.default.fileExists(atPath: url.path) }
        return try JSONDecoder().decode(ComputerResponse.self, from: Data(contentsOf: url))
    }
    func wait(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Computer fixture timed out", file: file, line: line); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func cleanUp() { provider.cleanUp(); controller.start(agents: [], monitoring: false); try? FileManager.default.removeItem(at: root) }
}
