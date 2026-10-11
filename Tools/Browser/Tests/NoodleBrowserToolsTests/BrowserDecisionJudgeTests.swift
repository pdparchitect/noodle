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

    func testRecommendMapsTheWinningOptionToItsElementTarget() async throws {
        let serving = Serving(answers: ["pick": DecisionAnswer(choice: "e02", probabilities: ["e01": 0.02, "e02": 0.97], confidence: 0.97, calibrated: true)])
        let elements = [
            ["rank": 1, "tag": "a", "target": "a:nth-of-type(1)", "label": "Continue shopping", "visible": true],
            ["rank": 2, "tag": "button", "target": "#checkout", "label": "Continue to payment", "visible": true],
        ]
        let pick = try await BrowserDecisionJudge(serving: serving).recommend(query: "proceed to payment", elements: elements)
        let answer = try XCTUnwrap(pick)
        XCTAssertEqual(answer.target, "#checkout")
        XCTAssertEqual(answer.confidence, 0.97)
        let question = try XCTUnwrap(serving.asked.first?["pick"])
        guard case .choice(let instructions, let criteria) = question else { return XCTFail("pick must be a choice question") }
        XCTAssertTrue(instructions.contains("proceed to payment"), "the task rides in the instructions")
        XCTAssertEqual(criteria["e02"], "rank 2 button \"Continue to payment\"", "the description carries rank, tag and label")
    }

    func testRecommendIgnoresUnknownAndLowConfidenceOptions() async throws {
        let outOfRange = Serving(answers: ["pick": DecisionAnswer(choice: "e09", confidence: 0.99, calibrated: true)])
        let nilPick = try await BrowserDecisionJudge(serving: outOfRange).recommend(query: "q", elements: [["rank": 1, "tag": "button", "target": "#a"]])
        XCTAssertNil(nilPick, "an option outside the candidate list picks nothing")

        let lowConfidence = Serving(answers: ["pick": DecisionAnswer(choice: "e01", probabilities: ["e01": 0.4], confidence: 0.4, calibrated: true)])
        let judged = try await BrowserDecisionJudge(serving: lowConfidence).recommend(query: "q", elements: [["rank": 1, "tag": "button", "target": "#a"]])
        XCTAssertEqual(judged?.target, "#a", "the judge reports; the provider's gate decides what surfaces")

        let noAnswer = Serving(answers: [:])
        let empty = try await BrowserDecisionJudge(serving: noAnswer).recommend(query: "q", elements: [["rank": 1, "tag": "button", "target": "#a"]])
        XCTAssertNil(empty)
    }
}