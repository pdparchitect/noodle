import XCTest
@testable import NoodleCore

final class CodexInspectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-codex-inspection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testModelsAreReadOverTheAppServerHandshake() throws {
        let models = try CodexInspection.models(executable: try fixture("""
            read initialize; echo '{"id":1,"result":{}}'
            read initialized
            read list
            echo '{"method":"notice","params":{}}'
            echo '{"id":2,"result":{"data":[{"model":"gpt-test","displayName":"GPT Test","isDefault":true,"defaultReasoningEffort":"high","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"high"}]},{"unnamed":true}]}}'
            sleep 5
            """), environment: ["PATH": "/usr/bin:/bin"], clientVersion: "1.0")
        XCTAssertEqual(models.map(\.id), ["gpt-test"])
        XCTAssertEqual(models.first?.displayName, "GPT Test")
        XCTAssertEqual(models.first?.supportedEfforts.map(\.id), ["low", "high"])
        XCTAssertEqual(models.first?.defaultEffort, "high")
        XCTAssertEqual(models.first?.isDefault, true)
    }

    func testErrorsAndSilenceAreReported() throws {
        XCTAssertThrowsError(try CodexInspection.models(executable: try fixture("""
            read initialize; echo '{"id":1,"error":{"message":"Not signed in"}}'; sleep 5
            """), environment: [:], clientVersion: "1.0")) { XCTAssertEqual($0.localizedDescription, "Not signed in") }
        XCTAssertThrowsError(try CodexInspection.models(executable: try fixture("exit 0"), environment: [:], clientVersion: "1.0"))
        XCTAssertThrowsError(try CodexInspection.models(executable: try fixture("sleep 5"), environment: [:], clientVersion: "1.0", timeout: 0.3))
    }

    func testRelayedSignInPageMustBeOpenAIsDevicePage() {
        XCTAssertEqual(CodexSetupProvider.relayedChallenge(url: "https://auth.openai.com/codex/device", code: "ABCD-1234")?.code, "ABCD-1234")
        XCTAssertNil(CodexSetupProvider.relayedChallenge(url: "https://auth.openai.com.example.com/codex/device", code: "ABCD-1234"))
        XCTAssertNil(CodexSetupProvider.relayedChallenge(url: "https://auth.openai.com/elsewhere", code: "ABCD-1234"))
        XCTAssertNil(CodexSetupProvider.relayedChallenge(url: "https://auth.openai.com/codex/device", code: ""))
    }

    private func fixture(_ body: String) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
