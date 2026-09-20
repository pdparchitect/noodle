import XCTest
@testable import NoodleCore

/// Both ends of the extension contract over a real NSXPC connection. An anonymous
/// listener stands in for the ExtensionKit process, so no extension has to be installed.
final class ToolExtensionTests: XCTestCase, NSXPCListenerDelegate {
    private struct Files: ToolProvider {
        let kind = ToolProviderKind.builtIn
        let manifest = ToolProviderManifest(id: "files", title: "Files", summary: "Copies", instructions: "Be careful.",
                                            activation: .whenAssigned("files"))
        func tools(context: ToolCallContext) async throws -> Data {
            Data(#"{"tools":[{"name":"copy","inputSchema":{"type":"object","properties":{"from":{"type":"string","format":"noodle-file"},"to":{"type":"string","format":"noodle-file","noodle/access":"write"}}}}]}"#.utf8)
        }
        func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
            guard tool == "copy" else { throw ToolProviderError("Unknown tool \(tool).") }
            let source = try XCTUnwrap(files.first { $0.parameter == "from" }), destination = try XCTUnwrap(files.first { $0.parameter == "to" })
            XCTAssertEqual([source.access, destination.access], [.read, .write])
            try destination.handle.write(contentsOf: source.handle.readToEnd() ?? Data())
            return try JSONSerialization.data(withJSONObject: ["content": [], "isError": false, "agent": context.agentID.uuidString,
                                                                   "assigned": context.assignments.ids("files").sorted()])
        }
    }

    private let listener = NSXPCListener.anonymous()
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        listener.delegate = self
        listener.resume()
    }
    override func tearDown() { listener.invalidate(); try? FileManager.default.removeItem(at: root) }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        ToolExtensionService(provider: Files()).accept(connection)
    }

    private func connect() async throws -> ToolExtensionConnection {
        try await ToolExtensionConnection(kind: .appExtension) { [endpoint = listener.endpoint] in NSXPCConnection(listenerEndpoint: endpoint) }
    }

    func testManifestToolsAndFileHandlesCrossTheConnection() async throws {
        let provider = try await connect()
        XCTAssertEqual(provider.manifest, Files().manifest)
        XCTAssertEqual(provider.kind, .appExtension)
        let context = ToolCallContext(agentID: UUID(), workspace: root, assignments: ["files": ["f2", "f1"]])
        let listed = try await provider.tools(context: context)
        XCTAssertEqual(try ToolDescriptor.list(mcp: listed).map(\.name), ["copy"])

        try Data("payload".utf8).write(to: root.appendingPathComponent("in"))
        FileManager.default.createFile(atPath: root.appendingPathComponent("out").path, contents: nil)
        let files = [ToolFile(parameter: "from", access: .read, handle: try FileHandle(forReadingFrom: root.appendingPathComponent("in"))),
                     ToolFile(parameter: "to", access: .write, handle: try FileHandle(forWritingTo: root.appendingPathComponent("out")))]
        let result = try JSONSerialization.jsonObject(with: try await provider.call("copy", arguments: Data("{}".utf8), files: files, context: context)) as? [String: Any]
        XCTAssertEqual(result?["agent"] as? String, context.agentID.uuidString)
        XCTAssertEqual(result?["assigned"] as? [String], ["f1", "f2"], "the calling bot's assignments reach the extension")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("out")), Data("payload".utf8))
    }

    func testProviderErrorsArriveAsErrorsAndTheConnectionSurvives() async throws {
        let provider = try await connect()
        let context = ToolCallContext(agentID: UUID(), workspace: root)
        do { _ = try await provider.call("missing", arguments: Data("{}".utf8), files: [], context: context); XCTFail("Expected an error.") }
        catch { XCTAssertEqual(error.localizedDescription, "Unknown tool missing.") }
        let listed = try await provider.tools(context: context)
        XCTAssertNoThrow(try ToolDescriptor.list(mcp: listed))
    }

    func testASilentExtensionFailsDiscoveryInsteadOfHangingIt() async throws {
        let silent = NSXPCListener.anonymous()
        final class Silent: NSObject, NSXPCListenerDelegate, ToolExtensionXPC {
            func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
                connection.exportedInterface = ToolExtensionInterface.make(); connection.exportedObject = self; connection.resume()
                return true
            }
            func manifest(reply: @escaping (Data) -> Void) {}
            func listTools(caller: Data, reply: @escaping (Data?, String?) -> Void) {}
            func callTool(_ name: String, arguments: Data, files: [FileHandle], parameters: [String], writable: [Bool],
                          caller: Data, reply: @escaping (Data?, String?) -> Void) {}
        }
        let delegate = Silent()
        silent.delegate = delegate; silent.resume()
        defer { silent.invalidate() }
        do {
            _ = try await ToolExtensionConnection(kind: .appExtension, manifestTimeout: 0.2) { [endpoint = silent.endpoint] in NSXPCConnection(listenerEndpoint: endpoint) }
            XCTFail("Expected a timeout.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription) }
    }

    func testAnInvalidManifestIsRejectedAtConnection() async throws {
        let bad = NSXPCListener.anonymous()
        final class Delegate: NSObject, NSXPCListenerDelegate {
            struct Bad: ToolProvider {
                let kind = ToolProviderKind.builtIn
                let manifest = ToolProviderManifest(id: "Not Valid", title: "", summary: "")
                func tools(context: ToolCallContext) async throws -> Data { Data() }
                func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data { Data() }
            }
            func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
                ToolExtensionService(provider: Bad()).accept(connection)
            }
        }
        let delegate = Delegate()
        bad.delegate = delegate; bad.resume()
        defer { bad.invalidate() }
        do { _ = try await ToolExtensionConnection(kind: .appExtension) { [endpoint = bad.endpoint] in NSXPCConnection(listenerEndpoint: endpoint) }; XCTFail("Expected an error.") } catch {}
    }
}
