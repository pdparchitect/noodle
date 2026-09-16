#if canImport(FoundationModels, _version: 2)
import XCTest
import FoundationModels
import NoodleCore
@testable import NoodleAppleRuntime

final class AppleMLXRecoveryLiveTests: XCTestCase {
    func testOptionalThinkingRecoveryProducesObservedToolResult() async throws {
        guard #available(macOS 27, *),
              let path = ProcessInfo.processInfo.environment["NOODLE_TEST_MLX_MODEL"] else {
            throw XCTSkip("Set NOODLE_TEST_MLX_MODEL to a toggleable local model for offline inference.")
        }
        try prepareMetalResource()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-recovery-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let bot = try repository.createAgent(named: "Recovery test", harnessIdentifier: "apple")
        let model = try AppleLocalModelStore(repository: root).importModel(from: URL(fileURLWithPath: path))
        let backend = try await AppleModelBackend.prepare(identifier: model.id, workspace: repository.directory(for: bot.agent))
        guard backend.canDisableReasoning else { throw XCTSkip("This model does not support disabling optional thinking.") }
        let control = AppleTurnControl()
        await control.recover()
        let value = UUID().uuidString.lowercased()
        let observed = RecoveryObservation(value: value)
        let session = backend.session(tools: [RecoveryObservationTool(observed: observed)],
            instructions: "Call observe once and report its exact value. Do not invent the value.", control: control)
        let response = try await AppleResponseRecovery.respond(session: session, prompt: Prompt("Read the observed value with observe and reply with it."),
            responseTokens: 256, control: control)
        XCTAssertTrue(response.contains(value), "The answer must come from the actual tool result")
        let calls = await observed.calls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(session.transcript.contains { entry in
            if case .reasoning(let reasoning) = entry { return !reasoning.segments.isEmpty }; return false
        }, "The MLX template should suppress optional thinking during recovery")
    }

    private func prepareMetalResource() throws {
        // XCTest runs in Apple's xctest host rather than beside the helper.
        // Make the already-built shaders discoverable through its test bundle.
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = project.appendingPathComponent(".build/mlx-metal/mlx.metallib")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Build MLX shaders with scripts/build-mlx-metal.sh before running local-model tests.")
        }
        let resources = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let bundle = resources.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents")
        let library = bundle.appendingPathComponent("Resources/default.metallib")
        try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: library.path) { try FileManager.default.removeItem(at: library) }
        try FileManager.default.copyItem(at: source, to: library)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.noodle.tests.mlx", "CFBundlePackageType": "BNDL"], format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"))
    }
}

@available(macOS 27, *)
private actor RecoveryObservation {
    let value: String
    var calls = 0
    init(value: String) { self.value = value }
    func read() -> String { calls += 1; return value }
}

@available(macOS 27, *)
private struct RecoveryObservationTool: Tool {
    let observed: RecoveryObservation
    let name = "observe"
    let description = "Read the actual value."
    @Generable struct Arguments { let label: String }
    func call(arguments: Arguments) async throws -> String { await observed.read() }
}
#endif
