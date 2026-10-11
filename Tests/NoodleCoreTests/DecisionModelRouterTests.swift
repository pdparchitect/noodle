import NoodleCore
import XCTest

/// Routing semantics: image states go to vision-capable backends only, text
/// states prefer the chosen model and fall back on-device, and total failure
/// propagates so callers can keep their unverified behavior.
final class DecisionModelRouterTests: XCTestCase {
    final class Recording: DecisionModelServing, @unchecked Sendable {
        let images: Bool
        let available: Bool
        let error: Error?
        private(set) var calls = 0
        init(images: Bool = false, available: Bool = true, error: Error? = nil) {
            self.images = images
            self.available = available
            self.error = error
        }
        var isAvailable: Bool { available }
        var supportsImages: Bool { images }
        func decide(state: [String: any Sendable], questions: [String: DecisionQuestion]) async throws -> [String: DecisionAnswer] {
            calls += 1
            if let error { throw error }
            return ["settled": DecisionAnswer(noul: 0.9, calibrated: true)]
        }
    }

    private func questions() -> [String: DecisionQuestion] {
        ["settled": .noul(instructions: "Settled?")]
    }

    func testImageStateSkipsNonVisionPreferredModel() async throws {
        let preferred = Recording()
        let vision = Recording(images: true)
        let router = DecisionModelRouter(preferred: preferred, visionFallbacks: [vision])
        let answers = try await router.decide(state: ["shot": DecisionImage(data: Data([1]), label: "s")], questions: questions())
        XCTAssertEqual(answers["settled"]?.noul, 0.9)
        XCTAssertEqual(preferred.calls, 0, "A text-only model must not judge an image state.")
        XCTAssertEqual(vision.calls, 1)
    }

    func testImageStateFallsThroughToSecondVisionBackend() async throws {
        let deadVision = Recording(images: true, error: HarnessSetupError("boom"))
        let liveVision = Recording(images: true)
        let router = DecisionModelRouter(preferred: Recording(), visionFallbacks: [deadVision, liveVision])
        _ = try await router.decide(state: ["shot": DecisionImage(data: Data([1]), label: "s")], questions: questions())
        XCTAssertEqual(deadVision.calls, 1)
        XCTAssertEqual(liveVision.calls, 1)
    }

    func testTextStateFallsBackOnDeviceWhenPreferredFails() async throws {
        let dead = Recording(error: HarnessSetupError("boom"))
        let router = DecisionModelRouter(preferred: dead)
        guard AppleDecisionModel().isAvailable else { throw XCTSkip("No on-device model on this Mac.") }
        let answers = try await router.decide(state: ["page": "done"], questions: questions())
        XCTAssertNotNil(answers["settled"])
        XCTAssertEqual(dead.calls, 1)
    }

    func testNoVisionBackendThrowsForImageState() async throws {
        let router = DecisionModelRouter(preferred: Recording())
        do {
            _ = try await router.decide(state: ["shot": DecisionImage(data: Data([1]), label: "s")], questions: questions())
            XCTFail("An image state with no vision backend must fail, not guess.")
        } catch {}
    }
}
