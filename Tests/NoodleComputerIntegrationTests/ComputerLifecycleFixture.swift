import ComputerBridge
import Foundation
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
    func send(_ request: ComputerRequest, agent: AgentRecord? = nil, edit: (inout ComputerAgentRequest) -> Void = { _ in }) throws -> URL {
        let agent = agent ?? a
        let bridge = try ComputerAgentSkill.bridge(workspace: repository.directory(for: agent))
        let session = try JSONDecoder().decode(MCPBridgeSession.self, from: Data(contentsOf: bridge.appendingPathComponent("session.json")))
        var envelope = ComputerAgentRequest(token: session.token, request: request)
        edit(&envelope)
        let stem = bridge.appendingPathComponent(envelope.id.uuidString.lowercased())
        try WorkspaceMailbox(workspace: repository.directory(for: agent), path: ".noodle/computer-bridge")
            .write(envelope, named: stem.lastPathComponent + ".request")
        controller.scan()
        return stem.appendingPathExtension("response")
    }
    func response(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async throws -> ComputerResponse {
        try await wait(file: file, line: line) { FileManager.default.fileExists(atPath: url.path) }
        return try JSONDecoder().decode(ComputerResponse.self, from: Data(contentsOf: url))
    }
    func wait(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Computer fixture timed out", file: file, line: line); throw CancellationError() }
            // Monitoring is disabled to keep provider handshakes under test control.
            // Pump the broker here: send() can scan before the vnode event arrives.
            controller.scan()
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func cleanUp() { provider.cleanUp(); controller.start(agents: [], monitoring: false); try? FileManager.default.removeItem(at: root) }
}
