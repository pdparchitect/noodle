import XCTest
@testable import NoodleCore

final class AgentTypingTests: XCTestCase {
    private let bot = UUID()
    private let other = UUID()
    private let direct = UUID()
    private let group = UUID()

    private func snapshot(_ phase: AgentRuntimePhase, _ agentID: UUID? = nil) -> AgentRuntimeSnapshot {
        AgentRuntimeSnapshot(agentID: agentID ?? bot, phase: phase, detail: "")
    }

    func testTypingOnlyInNotifiedConversationWhileBusy() {
        var tracker = AgentTypingTracker()
        tracker.expectReply(from: [bot], in: direct)
        XCTAssertTrue(tracker.isTyping(bot, in: direct, phase: .working))
        XCTAssertTrue(tracker.isTyping(bot, in: direct, phase: .starting))
        XCTAssertFalse(tracker.isTyping(bot, in: direct, phase: .ready))
        XCTAssertFalse(tracker.isTyping(bot, in: direct, phase: .failed))
        XCTAssertFalse(tracker.isTyping(bot, in: group, phase: .working))
        XCTAssertFalse(tracker.isTyping(other, in: direct, phase: .working))
    }

    func testUnnotifiedWorkSuchAsHeartbeatsIsNotTyping() {
        let tracker = AgentTypingTracker()
        XCTAssertFalse(tracker.isTyping(bot, in: direct, phase: .working))
    }

    func testFinishedTurnClearsEveryConversation() {
        var tracker = AgentTypingTracker()
        tracker.expectReply(from: [bot], in: direct)
        tracker.expectReply(from: [bot], in: group)
        tracker.update(snapshot(.working), hasPendingWork: true)
        tracker.update(snapshot(.ready), hasPendingWork: false)
        XCTAssertFalse(tracker.isTyping(bot, in: direct, phase: .working))
        XCTAssertFalse(tracker.isTyping(bot, in: group, phase: .working))
    }

    func testQueuedMessageSurvivesTheReadyBetweenTurns() {
        var tracker = AgentTypingTracker()
        tracker.expectReply(from: [bot], in: direct)
        tracker.update(snapshot(.ready), hasPendingWork: true)
        XCTAssertTrue(tracker.isTyping(bot, in: direct, phase: .working))
    }

    func testInterruptedWorkSurvivesFailureForRecovery() {
        var tracker = AgentTypingTracker()
        tracker.expectReply(from: [bot], in: direct)
        tracker.update(snapshot(.failed), hasPendingWork: true)
        XCTAssertTrue(tracker.isTyping(bot, in: direct, phase: .starting))
        tracker.update(snapshot(.failed), hasPendingWork: false)
        XCTAssertFalse(tracker.isTyping(bot, in: direct, phase: .starting))
    }

    func testReplyHidesTypingUntilResumed() {
        var tracker = AgentTypingTracker()
        tracker.expectReply(from: [bot], in: direct)
        let token = tracker.pause(bot, in: direct)
        XCTAssertNotNil(token)
        XCTAssertFalse(tracker.isTyping(bot, in: direct, phase: .working))
        tracker.resume(bot, in: direct, token: token!)
        XCTAssertTrue(tracker.isTyping(bot, in: direct, phase: .working))
    }

    func testOnlyTheLatestReplyResumesTyping() {
        var tracker = AgentTypingTracker()
        tracker.expectReply(from: [bot], in: direct)
        let first = tracker.pause(bot, in: direct)!
        _ = tracker.pause(bot, in: direct)
        tracker.resume(bot, in: direct, token: first)
        XCTAssertFalse(tracker.isTyping(bot, in: direct, phase: .working))
    }

    func testReplyInUnexpectedConversationIsIgnored() {
        var tracker = AgentTypingTracker()
        XCTAssertNil(tracker.pause(bot, in: direct))
    }

    func testNewUserMessageOrNextTurnShowsTypingAgain() {
        var tracker = AgentTypingTracker()
        tracker.expectReply(from: [bot], in: direct)
        _ = tracker.pause(bot, in: direct)
        tracker.expectReply(from: [bot], in: direct)
        XCTAssertTrue(tracker.isTyping(bot, in: direct, phase: .working))

        _ = tracker.pause(bot, in: direct)
        tracker.update(snapshot(.ready), hasPendingWork: true)
        XCTAssertTrue(tracker.isTyping(bot, in: direct, phase: .working))
    }

    func testFinishedTurnDiscardsPendingResume() {
        var tracker = AgentTypingTracker()
        tracker.expectReply(from: [bot], in: direct)
        let token = tracker.pause(bot, in: direct)!
        tracker.update(snapshot(.ready), hasPendingWork: false)
        tracker.resume(bot, in: direct, token: token)
        XCTAssertFalse(tracker.isTyping(bot, in: direct, phase: .working))
    }

    func testOneBotFinishingDoesNotClearAnother() {
        var tracker = AgentTypingTracker()
        tracker.expectReply(from: [bot, other], in: group)
        tracker.update(snapshot(.ready, other), hasPendingWork: false)
        XCTAssertTrue(tracker.isTyping(bot, in: group, phase: .working))
        XCTAssertFalse(tracker.isTyping(other, in: group, phase: .working))
        tracker.remove(bot)
        XCTAssertFalse(tracker.isTyping(bot, in: group, phase: .working))
    }
}
