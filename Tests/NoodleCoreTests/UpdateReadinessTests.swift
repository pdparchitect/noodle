import XCTest
@testable import NoodleCore

final class UpdateReadinessTests: XCTestCase {
    func testIdleOfflineAndFailedAgentsDoNotBlockAnUpdate() {
        XCTAssertTrue(ready([.ready, .offline, .failed]))
        XCTAssertTrue(ready([]))
    }

    func testStartingAndWorkingAgentsBlockAnUpdate() {
        XCTAssertFalse(ready([.ready, .starting]))
        XCTAssertFalse(ready([.working, .ready]))
    }

    func testUnsentMessagesAttachmentsAndOpenEditorsBlockAnUpdate() {
        XCTAssertFalse(ready([], draft: "unsent message"))
        XCTAssertFalse(ready([], attachments: true))
        XCTAssertFalse(ready([], editing: true))
        XCTAssertTrue(ready([], draft: " \n\t"))
    }

    func testFinishingWorkMakesTheDeferredUpdateReady() {
        XCTAssertFalse(ready([.working], draft: "draft"))
        XCTAssertFalse(ready([.ready], draft: "draft"))
        XCTAssertTrue(ready([.ready]))
    }

    func testSleepPreventionIsOptInAndOnlyAppliesWhileWorking() {
        XCTAssertFalse(AgentSleepPolicy.shouldPreventIdleSleep(enabled: false, phases: [.working]))
        XCTAssertFalse(AgentSleepPolicy.shouldPreventIdleSleep(enabled: true, phases: [.ready, .starting]))
        XCTAssertTrue(AgentSleepPolicy.shouldPreventIdleSleep(enabled: true, phases: [.ready, .working]))
    }

    private func ready(
        _ phases: [AgentRuntimePhase], draft: String = "",
        attachments: Bool = false, editing: Bool = false
    ) -> Bool {
        UpdateReadiness.canRelaunch(
            phases: phases, draft: draft, hasAttachments: attachments, isEditing: editing
        )
    }
}
