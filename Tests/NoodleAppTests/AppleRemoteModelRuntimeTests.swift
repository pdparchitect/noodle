import Foundation
import NoodleCore
import XCTest
@testable import NoodleRuntime

/// The app holds remote-model keys; the bot's Apple harness receives its
/// account's key with the model selection, and nothing else does.
@MainActor final class AppleRemoteModelRuntimeTests: XCTestCase {
    func testRemoteModelSelectionCarriesTheAccountKeyAndEffort() async throws {
        let f = try HarnessRuntimeFixture(); defer { f.cleanUp() }
        let wire = HarnessWire()
        let id = RemoteModelID(providerID: "openai", accountID: UUID(), modelID: "gpt-6-luna")
        var asked: [RemoteModelID] = []
        f.acp(wire, provider: .apple, extended: false, model: id.rawValue) { requested in
            asked.append(requested)
            return RemoteModelAccess(apiKey: "sk-fixture", model: nil)
        }.start()
        try await f.openACP(wire, provider: .apple)
        let params = try XCTUnwrap(wire.last("session/set_model")["params"] as? [String: Any])
        XCTAssertEqual(params["modelId"] as? String, id.rawValue)
        let access = try XCTUnwrap((params["_meta"] as? [String: Any])?["noodle/remote"] as? [String: Any])
        XCTAssertEqual(access["apiKey"] as? String, "sk-fixture")
        XCTAssertEqual(access["effort"] as? String, "high")
        XCTAssertNil(access["model"])
        XCTAssertEqual(asked, [id])
    }

    func testOllamaSelectionCarriesTheModelFoundOnTheServer() async throws {
        let f = try HarnessRuntimeFixture(); defer { f.cleanUp() }
        let wire = HarnessWire()
        let id = RemoteModelID(providerID: "ollama", accountID: UUID(), modelID: "qwen3:8b")
        let qwen = RemoteModelInfo(id: "qwen3:8b", displayName: "qwen3:8b", contextSize: 16_384, maximumOutputTokens: 4_096,
                                   supportsImages: false, efforts: [], defaultEffort: "")
        f.acp(wire, provider: .apple, extended: false, model: id.rawValue) { _ in RemoteModelAccess(apiKey: "", model: qwen) }.start()
        try await f.openACP(wire, provider: .apple)
        let params = try XCTUnwrap(wire.last("session/set_model")["params"] as? [String: Any])
        let access = try XCTUnwrap((params["_meta"] as? [String: Any])?["noodle/remote"] as? [String: Any])
        XCTAssertEqual(access["apiKey"] as? String, "")
        XCTAssertEqual(try RemoteModelAccess(access).model, qwen)
    }

    func testOtherModelsAreSelectedWithoutAKey() async throws {
        let f = try HarnessRuntimeFixture(); defer { f.cleanUp() }
        let wire = HarnessWire()
        f.acp(wire, provider: .apple, extended: false, model: "default") { _ in
            XCTFail("Only remote models need a key")
            return RemoteModelAccess(apiKey: "", model: nil)
        }.start()
        try await f.openACP(wire, provider: .apple)
        XCTAssertNil((try wire.last("session/set_model")["params"] as? [String: Any])?["_meta"])
    }

    func testMissingKeyStopsTheBotWithTheReason() async throws {
        let f = try HarnessRuntimeFixture(); defer { f.cleanUp() }
        let wire = HarnessWire()
        let id = RemoteModelID(providerID: "openai", accountID: UUID(), modelID: "gpt-6-luna")
        f.acp(wire, provider: .apple, extended: false, model: id.rawValue) { _ in
            throw HarnessSetupError("The API key for this account is missing.")
        }.start()
        try await f.wait { wire.count("initialize") > 0 }
        try wire.reply("initialize", result: ["protocolVersion": 1, "agentInfo": ["version": "1"]])
        try await f.wait { wire.count("session/new") > 0 }
        try wire.reply("session/new", result: ["sessionId": "fixture-session"])
        try await f.wait { f.failures.contains { $0.0.contains("The API key for this account is missing.") } }
        XCTAssertEqual(wire.count("session/set_model"), 0, "Nothing is selected without the key")
    }
}
