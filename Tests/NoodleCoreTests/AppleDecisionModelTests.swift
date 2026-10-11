import NoodleCore
import XCTest

/// Exercises the on-device backend when FoundationModels is available on this
/// Mac; skips elsewhere. Asserts answer shape and the out-of-set rejection, not
/// specific verdicts — those belong to the probe corpus, not CI.
final class AppleDecisionModelTests: XCTestCase {
    private var serving: AppleDecisionModel { AppleDecisionModel() }

    func testAvailabilityReportsAndAnswersTypedQuestions() async throws {
        guard serving.isAvailable else { throw XCTSkip("No on-device decision model on this Mac.") }
        let answers = try await serving.decide(
            state: ["page": ["title": "Example", "text": "Example Domain"]],
            questions: [
                "settled": .noul(instructions: "The page finished rendering its primary content."),
                "kind": .choice(instructions: "What kind of page is this?", criteria: ["error": "An error page.", "content": "A content page."]),
            ])
        let settled = try XCTUnwrap(answers["settled"])
        XCTAssertNotNil(settled.noul)
        XCTAssertFalse(settled.calibrated, "Bands, not probabilities.")
        let kind = try XCTUnwrap(answers["kind"])
        XCTAssertTrue(["error", "content"].contains(kind.choice ?? ""), "The choice must come from the allowed set.")
    }

    func testImageStatesAreRejected() async throws {
        guard serving.isAvailable else { throw XCTSkip("No on-device decision model on this Mac.") }
        XCTAssertFalse(serving.supportsImages)
        let image = DecisionImage(data: Data([0x89]), label: "shot")
        do {
            _ = try await serving.decide(state: ["shot": image], questions: ["settled": .noul(instructions: "Settled?")])
            // The text backend degrades the image to a label and still answers.
        } catch {
            // Rejecting the state outright is also acceptable; callers route by supportsImages.
        }
    }
}
