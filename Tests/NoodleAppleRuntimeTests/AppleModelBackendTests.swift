import XCTest
import FoundationModels
import NoodleCore
@testable import NoodleAppleRuntime

final class AppleModelBackendTests: XCTestCase {
    func testInspectionRetainsDefaultIdentifierAndReportsBuildCapability() {
        let result = AppleModel.inspection(version: "test")
        XCTAssertEqual(result.models.map(\.id), ["default"])
        XCTAssertEqual(result.version, "test")
        #if canImport(FoundationModels, _version: 2)
        if #available(macOS 27, *) { XCTAssertEqual(result.localModelsSupported, true) }
        #else
        XCTAssertEqual(result.localModelsSupported, false)
        #endif
    }

    func testUnknownModelCannotSilentlyFallBackToApple() async throws {
        guard #available(macOS 26, *) else { return }
        do {
            _ = try await AppleModelBackend.prepare(identifier: "missing-model", workspace: FileManager.default.temporaryDirectory)
            XCTFail("Invalid selection unexpectedly loaded a model")
        } catch { /* A missing/invalid selection must be reported. */ }
    }

    func testSavedModelIdentityAndLegacyTranscriptDecoding() throws {
        guard #available(macOS 26, *) else { return }
        let session = AppleConversationSession(transcript: Transcript(entries: []), messageIDs: [], reply: "done", modelIdentifier: "default")
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(AppleConversationSession.self, from: data).modelIdentifier, "default")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "modelIdentifier")
        XCTAssertNil(try JSONDecoder().decode(AppleConversationSession.self, from: JSONSerialization.data(withJSONObject: json)).modelIdentifier)
    }
}
