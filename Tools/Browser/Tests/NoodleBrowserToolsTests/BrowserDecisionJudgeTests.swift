import BrowserBridge
import NoodleCore
import XCTest
@testable import NoodleBrowserTools

/// The decision layer over a page's settle signals: question phrasing, answer
/// mapping, and the fail-open rules that keep a bot unverified but working.
final class BrowserDecisionJudgeTests: XCTestCase {
    final class Serving: DecisionModelServing, @unchecked Sendable {
        var asked: [[String: DecisionQuestion]] = []
        var answers: [String: DecisionAnswer]
        init(answers: [String: DecisionAnswer]) { self.answers = answers }
        var isAvailable: Bool { true }
        var supportsImages: Bool { false }
        func decide(state: [String: any Sendable], questions: [String: DecisionQuestion]) async throws -> [String: DecisionAnswer] {
            asked.append(questions)
            return answers
        }
    }

    private func signals(overlayText: String? = nil, overlayMatches: [String]? = nil) -> BrowserSettleSignals {
        BrowserSettleSignals(url: "https://example.com/", title: "Example", readyState: "complete",
                             loading: false, spinners: 0, mutations: 2, activeResources: 0,
                             overlayText: overlayText, overlayMatches: overlayMatches)
    }

    func testSettledAnswerMapsIntoTheJudgement() async throws {
        let serving = Serving(answers: ["settled": DecisionAnswer(noul: 0.98, calibrated: true)])
        let answered = try await BrowserDecisionJudge(serving: serving).judge(signals())
        let judgement = try XCTUnwrap(answered)
        XCTAssertTrue(judgement.settled)
        XCTAssertEqual(judgement.settledProbability, 0.98)
        XCTAssertTrue(judgement.calibrated)
        XCTAssertNil(judgement.blocker)
        XCTAssertEqual(serving.asked.first.map { Set($0.keys) }, ["settled"], "no overlay, no blocker question")
    }

    func testUnsettledPageStaysBelowTheGate() async throws {
        let serving = Serving(answers: ["settled": DecisionAnswer(noul: 0.2, calibrated: true)])
        let answered = try await BrowserDecisionJudge(serving: serving).judge(signals())
        let judgement = try XCTUnwrap(answered)
        XCTAssertFalse(judgement.settled)
    }
    func testOverlayFactsTriggerTheBlockerQuestionAndNoneMeansNoBlocker() async throws {
        let serving = Serving(answers: [
            "settled": DecisionAnswer(noul: 0.9, calibrated: true),
            "blocker": DecisionAnswer(choice: "none", confidence: 0.9, calibrated: true),
        ])
        let answered = try await BrowserDecisionJudge(serving: serving).judge(
            signals(overlayText: "We value your privacy", overlayMatches: ["cookie"]))
        let judgement = try XCTUnwrap(answered)
        XCTAssertNil(judgement.blocker, "none collapses to no blocker")
        let questions = try XCTUnwrap(serving.asked.first)
        XCTAssertEqual(Set(questions.keys), ["settled", "blocker"])
    }
    func testBlockerChoiceTravelsWithConfidence() async throws {
        let serving = Serving(answers: [
            "settled": DecisionAnswer(noul: 0.9, calibrated: true),
            "blocker": DecisionAnswer(choice: "captcha", confidence: 0.85, calibrated: true),
        ])
        let answered = try await BrowserDecisionJudge(serving: serving).judge(
            signals(overlayText: "Verify you are human", overlayMatches: ["captcha"]))
        let judgement = try XCTUnwrap(answered)
        XCTAssertEqual(judgement.blocker, "captcha")
        XCTAssertEqual(judgement.blockerConfidence, 0.85)
    }

    func testAThrowingServingYieldsNoJudgement() async throws {
        final class Broken: DecisionModelServing, @unchecked Sendable {
            var isAvailable: Bool { true }
            var supportsImages: Bool { false }
            struct Boom: Error {}
            func decide(state: [String: any Sendable], questions: [String: DecisionQuestion]) async throws -> [String: DecisionAnswer] { throw Boom() }
        }
        // The judge propagates the serving's error; fail-open now lives in
        // DecisionModelServingCache, which drops the serving and answers nil.
        do {
            _ = try await BrowserDecisionJudge(serving: Broken()).judge(signals())
            XCTFail("Expected the serving's error to propagate.")
        } catch {}
    }
}