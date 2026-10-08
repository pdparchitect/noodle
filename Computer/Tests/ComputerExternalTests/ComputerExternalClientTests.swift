import ComputerBridge
@testable import ComputerExternal
import Foundation
import Testing

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ComputerRequest] = []
    func append(_ request: ComputerRequest) { lock.withLock { requests.append(request) } }
    var all: [ComputerRequest] { lock.withLock { requests } }
}

private let dev = RemoteComputer(id: UUID(), name: "Dev", kind: "Linux", state: "Running", symbol: "terminal")
private let lab = RemoteComputer(id: UUID(), name: "Lab", kind: "Linux", state: "Stopped", symbol: "terminal")

private func client(_ computers: [RemoteComputer], environment: [String: String] = [:], root: URL? = nil, calls: Calls = Calls(),
                    answer: @escaping @Sendable (ComputerRequest, URL?) throws -> ComputerResponse = { _, _ in ComputerResponse() }) -> ComputerExternalClient {
    ComputerExternalClient(environment: environment, directory: URL(fileURLWithPath: "/tmp"),
        stagingRoot: { try root ?? { throw ComputerBridgeError("No staging in this test.") }() }) { request in
        calls.append(request)
        if request.operation == .list { return ComputerResponse(computers: computers) }
        let payload = try request.transferID.map { try ComputerTransferFiles.staging(root: root!, id: $0, create: false) }
        return try answer(request, payload)
    }
}

@Suite struct ComputerExternalClientTests {
    @Test func commandLineArgumentsBecomeAnOperationAndOptions() throws {
        let (operation, options) = try ComputerExternalClient.parse(["write", "--computer", "Dev", "--terminal", "T", "--text", "ls"])
        #expect(operation == .terminalWrite)
        #expect(options["text"] as? String == "ls")
        #expect(throws: ComputerBridgeError.self) { try ComputerExternalClient.parse(["present"]) }
        #expect(throws: ComputerBridgeError.self) { try ComputerExternalClient.parse(["setOwner"]) }
        #expect(throws: ComputerBridgeError.self) { try ComputerExternalClient.parse(["write", "--conversation", "C"]) }
    }

    @Test func eachCommandHasItsOwnHelp() {
        let write = ComputerExternalClient.usage(for: "write")
        #expect(write?.contains("--terminal") == true && write?.contains("--base64") == true)
        #expect(write?.contains("download") == false)
        #expect(ComputerExternalClient.usage(for: "present") == nil)
    }

    @Test func theComputerCanBeLeftOutWhenThereIsOnlyOne() async throws {
        let calls = Calls()
        _ = try await client([dev], calls: calls).run(.start, options: [:])
        #expect(calls.all.last?.computerID == dev.id)
        await #expect(throws: ComputerBridgeError.self) { try await client([dev, lab]).run(.start, options: [:]) }
        _ = try await client([dev, lab], environment: ["NOODLE_COMPUTER": "lab"], calls: calls).run(.start, options: [:])
        #expect(calls.all.last?.computerID == lab.id)
    }

    @Test func writingSendsTextWithEnterOrExactBytes() async throws {
        let calls = Calls(), terminal = UUID()
        _ = try await client([dev], calls: calls).run(.terminalWrite, options: ["terminal": terminal.uuidString, "text": "ls"])
        #expect(calls.all.last?.data == Data("ls\r".utf8))
        #expect(calls.all.last?.terminalID == terminal)
        _ = try await client([dev], calls: calls).run(.terminalWrite, options: ["terminal": terminal.uuidString, "base64": Data([3]).base64EncodedString()])
        #expect(calls.all.last?.data == Data([3]))
        await #expect(throws: ComputerBridgeError.self) { try await client([dev]).run(.terminalWrite, options: ["terminal": terminal.uuidString]) }
    }

    @Test func readingAnswersWithText() async throws {
        let result = try await client([dev]) { _, _ in ComputerResponse(data: Data("hello\n".utf8), offset: 6) }
            .run(.terminalRead, options: ["terminal": UUID().uuidString, "offset": "0"])
        #expect(result["text"] as? String == "hello\n")
        #expect(result["data"] == nil && result["version"] == nil)
    }

    @Test func makingOneTakesItsTemplateAndName() async throws {
        let calls = Calls()
        _ = try await client([], calls: calls).run(.create, options: ["template": "ubuntu", "name": "Build box"])
        #expect(calls.all.last?.computer == ComputerDraft(template: "ubuntu", name: "Build box"))
        #expect(calls.all.last?.computerID == nil)
    }

    @Test func uploadsAndDownloadsMoveFilesBetweenThisMacAndTheGuest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: local)
        let calls = Calls()
        _ = try await client([dev], root: root, calls: calls) { request, payload in
            let staged = try Data(contentsOf: payload!)
            #expect(staged == Data("notes".utf8))
            var response = ComputerResponse(); response.byteCount = 5; response.path = request.path; return response
        }.run(.fileUpload, options: ["source": local.path, "destination": "/root/notes.txt"])
        #expect(calls.all.last?.path == "/root/notes.txt")
        let back = root.appendingPathComponent("back.txt")
        let result = try await client([dev], root: root) { _, payload in
            try Data("guest".utf8).write(to: payload!)
            var response = ComputerResponse(); response.byteCount = 5; return response
        }.run(.fileDownload, options: ["source": "/etc/hostname", "destination": back.path])
        #expect(try Data(contentsOf: back) == Data("guest".utf8))
        #expect(result["localPath"] as? String == back.path)
        await #expect(throws: ComputerBridgeError.self) {
            try await client([dev], root: root).run(.fileDownload, options: ["source": "/etc/hostname", "destination": back.path])
        }
    }

    @Test func theToolsAreWhatOutsideAppsMayCall() throws {
        let names = Set(ComputerExternalClient.tools().compactMap { $0["name"] as? String })
        #expect(names == Set(ComputerOperation.externalCases.map(\.command)))
        #expect(!names.contains("present") && !names.contains("surfaceStream") && !names.contains("setOwner"))
    }
}
