import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class MessageDeliveryRouterTests: XCTestCase {
    private func fixture(timeout: Duration = .seconds(30),
                         now: @escaping () -> ContinuousClock.Instant = { .now }) -> RoutingFixture {
        let fixture = RoutingFixture(timeout: timeout, now: now)
        addTeardownBlock { await MainActor.run { fixture.cleanUp() } }
        return fixture
    }

    private func finish(_ task: Task<Void, Never>?, file: StaticString = #filePath, line: UInt = #line) async {
        guard let task else { return XCTFail("Expected classification work", file: file, line: line) }
        let finished = XCTestExpectation(description: "routing work finished")
        Task { await task.value; finished.fulfill() }
        let outcome = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(outcome, .completed, file: file, line: line)
    }

    func testAutomaticDeliveryQueuesBeforeClassifyingAndPromotesTheSameWake() async throws {
        let f = fixture(), reply = f.classifier.next()
        let task = f.notify()
        let wake = try XCTUnwrap(f.process.pending.id)
        XCTAssertEqual(f.process.notifications.count, 1)
        XCTAssertFalse(f.process.pending.isImmediate)
        await fulfillment(of: [reply.entered], timeout: 2)
        XCTAssertEqual(f.classifier.contexts.first?.unreadMessages, RoutingFixture.context.unreadMessages)
        XCTAssertEqual(f.classifier.contexts.first?.recentMessages, RoutingFixture.context.recentMessages)
        XCTAssertTrue(f.process.promotions.isEmpty)
        reply.resolve(.success(true))
        await finish(task)
        XCTAssertEqual(f.process.promotions, [wake])
        XCTAssertEqual(f.process.notifications.count, 1, "Promotion must not enqueue another wake")
        XCTAssertEqual(f.process.pending.id, wake)
        XCTAssertTrue(f.process.pending.isImmediate)
    }

    func testExplicitModesDeliverWithoutLoadingContextOrClassifying() {
        for mode in [MessageDeliveryMode.queue, .immediate] {
            let f = fixture()
            f.mode(mode)
            let task = f.router.notify(f.process) { XCTFail("Explicit delivery must bypass context loading"); return nil }
            XCTAssertNil(task)
            XCTAssertEqual(f.process.notifications.count, 1)
            XCTAssertEqual(f.process.pending.isImmediate, mode == .immediate)
            XCTAssertTrue(f.classifier.contexts.isEmpty)
        }
    }

    func testNonWorkingAgentsAreNotDelayedByClassification() {
        for phase in [AgentRuntimePhase.ready, .starting, .offline, .failed] {
            let f = fixture()
            f.process.snapshot.phase = phase
            f.process.phaseAfterNotify = .working
            let task = f.router.notify(f.process) { XCTFail("Only already-working agents need classification"); return nil }
            XCTAssertNil(task)
            XCTAssertEqual(f.process.notifications.count, 1)
            XCTAssertFalse(f.process.pending.isImmediate)
            XCTAssertTrue(f.classifier.contexts.isEmpty)
        }
    }

    func testUnavailableClassifierLeavesNotificationQueuedWithoutReadingContext() {
        let f = fixture()
        f.classifier.isAvailable = false
        let task = f.router.notify(f.process) { XCTFail("Unavailable classification must not read conversation text"); return nil }
        XCTAssertNil(task)
        XCTAssertEqual(f.process.notifications.count, 1)
        XCTAssertTrue(f.process.pending.isPending)
        XCTAssertFalse(f.process.pending.isImmediate)
    }

    func testRoutineAndFailedClassificationsKeepTheOriginalWakeQueued() async {
        for result in [Result<Bool, Error>.success(false), .failure(FixtureError.unavailable)] {
            let f = fixture(), reply = f.classifier.next()
            let task = f.notify()
            let wake = f.process.pending.id
            await fulfillment(of: [reply.entered], timeout: 2)
            reply.resolve(result)
            await finish(task)
            XCTAssertEqual(f.process.pending.id, wake)
            XCTAssertFalse(f.process.pending.isImmediate)
            XCTAssertTrue(f.process.promotions.isEmpty)
            XCTAssertEqual(f.process.notifications.count, 1)
        }
    }

    func testMissingOrFailedContextLeavesNotificationQueued() async {
        for fails in [false, true] {
            let f = fixture()
            let task = f.router.notify(f.process) {
                if fails { throw FixtureError.unavailable }
                return nil
            }
            await finish(task)
            XCTAssertTrue(f.classifier.contexts.isEmpty)
            XCTAssertTrue(f.process.pending.isPending)
            XCTAssertFalse(f.process.pending.isImmediate)
            XCTAssertEqual(f.process.notifications.count, 1)
        }
    }

    func testChangingDeliveryModeDiscardsAnInFlightAutomaticDecision() async {
        for mode in [MessageDeliveryMode.queue, .immediate] {
            let f = fixture(), reply = f.classifier.next()
            let task = f.notify()
            await fulfillment(of: [reply.entered], timeout: 2)
            f.mode(mode)
            reply.resolve(.success(true))
            await finish(task)
            XCTAssertTrue(f.process.promotions.isEmpty)
            XCTAssertFalse(f.process.pending.isImmediate)
            XCTAssertEqual(f.process.notifications.count, 1)
        }
    }

    func testCancellationBeforeWorkStartsDoesNotReadContext() async {
        let f = fixture()
        var contextReads = 0
        let task = f.router.notify(f.process) { contextReads += 1; return RoutingFixture.context }
        f.router.cancel(for: f.process.configuration.id)
        await finish(task)
        XCTAssertEqual(contextReads, 0, "Cancelled routing must not begin loading conversation text")
        XCTAssertTrue(f.classifier.contexts.isEmpty)
        XCTAssertTrue(f.process.pending.isPending)
    }

    func testCancellationDuringContextLoadingRejectsItsLateAnswer() async {
        let f = fixture(), context = RoutingGate<MessageDeliveryContext?>()
        let task = f.router.notify(f.process) { try await context.value() }
        await fulfillment(of: [context.entered], timeout: 2)
        f.router.cancel(for: f.process.configuration.id)
        await fulfillment(of: [context.cancelled], timeout: 2)
        context.resolve(.success(RoutingFixture.context))
        await finish(task)
        XCTAssertTrue(f.classifier.contexts.isEmpty)
        XCTAssertTrue(f.process.promotions.isEmpty)
        XCTAssertTrue(f.process.pending.isPending)
    }

    func testTimeoutDuringContextLoadingPreventsClassification() async {
        let f = fixture(timeout: .milliseconds(50)), context = RoutingGate<MessageDeliveryContext?>()
        let task = f.router.notify(f.process) { try await context.value() }
        await fulfillment(of: [context.entered, context.cancelled], timeout: 2)
        context.resolve(.success(RoutingFixture.context))
        await finish(task)
        XCTAssertTrue(f.classifier.contexts.isEmpty)
        XCTAssertFalse(f.process.pending.isImmediate)
    }

    func testTimeoutRejectsLateClassifierSuccessAndNextNotificationStillWorks() async {
        let f = fixture(timeout: .milliseconds(50)), late = f.classifier.next()
        let task = f.notify()
        await fulfillment(of: [late.entered, late.cancelled], timeout: 2)
        late.resolve(.success(true))
        await finish(task)
        XCTAssertTrue(f.process.promotions.isEmpty)
        XCTAssertFalse(f.process.pending.isImmediate)
        let next = f.classifier.next()
        next.resolve(.success(true))
        await finish(f.notify())
        XCTAssertEqual(f.process.promotions, [f.process.pending.id!])
        XCTAssertTrue(f.process.pending.isImmediate)
    }

    func testSupersededCompletionCannotRemoveTheNewJobsCancellation() async {
        let f = fixture(), first = f.classifier.next(), second = f.classifier.next()
        let oldTask = f.notify()
        await fulfillment(of: [first.entered], timeout: 2)
        let newTask = f.notify()
        await fulfillment(of: [second.entered, first.cancelled], timeout: 2)
        first.resolve(.success(true))
        await finish(oldTask)
        f.router.cancel(for: f.process.configuration.id)
        await fulfillment(of: [second.cancelled], timeout: 2)
        second.resolve(.success(true))
        await finish(newTask)
        XCTAssertTrue(f.process.promotions.isEmpty)
        XCTAssertEqual(f.process.notifications.count, 2)
        XCTAssertEqual(f.process.notifications[0].id, f.process.notifications[1].id)
        XCTAssertFalse(f.process.pending.isImmediate)
    }

    func testNewerResultCanPromoteWhileSupersededClassifierIsStillPending() async {
        let f = fixture(), first = f.classifier.next(), second = f.classifier.next()
        let oldTask = f.notify()
        await fulfillment(of: [first.entered], timeout: 2)
        let newTask = f.notify()
        await fulfillment(of: [second.entered], timeout: 2)
        second.resolve(.success(true))
        await finish(newTask)
        XCTAssertEqual(f.process.promotions, [f.process.pending.id!])
        first.resolve(.success(true))
        await finish(oldTask)
        XCTAssertEqual(f.process.promotions.count, 1)
    }

    func testCancellingOneAgentLeavesTheOtherAgentsClassificationRunning() async {
        let f = fixture(), other = RoutingProcess()
        let first = f.classifier.next(), second = f.classifier.next()
        let firstTask = f.notify()
        await fulfillment(of: [first.entered], timeout: 2)
        let secondTask = f.notify(other)
        await fulfillment(of: [second.entered], timeout: 2)
        f.router.cancel(for: f.process.configuration.id)
        first.resolve(.success(true))
        second.resolve(.success(true))
        await finish(firstTask)
        await finish(secondTask)
        XCTAssertTrue(f.process.promotions.isEmpty)
        XCTAssertEqual(other.promotions, [other.pending.id!])
    }

    func testCancelAllDiscardsLateResultsForEveryAgent() async {
        let f = fixture(), other = RoutingProcess()
        let first = f.classifier.next(), second = f.classifier.next()
        let firstTask = f.notify()
        await fulfillment(of: [first.entered], timeout: 2)
        let secondTask = f.notify(other)
        await fulfillment(of: [second.entered], timeout: 2)
        f.router.cancelAll()
        f.router.cancelAll()
        await fulfillment(of: [first.cancelled, second.cancelled], timeout: 2)
        first.resolve(.success(true))
        second.resolve(.success(true))
        await finish(firstTask)
        await finish(secondTask)
        XCTAssertTrue(f.process.promotions.isEmpty)
        XCTAssertTrue(other.promotions.isEmpty)
        XCTAssertTrue(f.process.pending.isPending)
        XCTAssertTrue(other.pending.isPending)
    }

    func testLateClassificationCannotPromoteAWakeCreatedAfterOriginalDelivery() async throws {
        let f = fixture(), reply = f.classifier.next()
        let task = f.notify()
        await fulfillment(of: [reply.entered], timeout: 2)
        let delivered = try XCTUnwrap(f.process.pending.take())
        let newer = f.process.notify(immediately: false)
        XCTAssertNotEqual(delivered, newer)
        reply.resolve(.success(true))
        await finish(task)
        XCTAssertEqual(f.process.promotions, [delivered], "The router must retain the identity it originally queued")
        XCTAssertEqual(f.process.pending.id, newer)
        XCTAssertFalse(f.process.pending.isImmediate, "An old decision must not interrupt a newer turn")
    }

    func testReplacingAProcessCancelsItsOldClassification() async {
        let f = fixture(), replacement = RoutingProcess(agent: f.process.configuration)
        let first = f.classifier.next(), second = f.classifier.next()
        let oldTask = f.notify()
        await fulfillment(of: [first.entered], timeout: 2)
        let newTask = f.notify(replacement)
        await fulfillment(of: [first.cancelled, second.entered], timeout: 2)
        first.resolve(.success(true))
        second.resolve(.success(true))
        await finish(oldTask)
        await finish(newTask)
        XCTAssertTrue(f.process.promotions.isEmpty)
        XCTAssertEqual(replacement.promotions, [replacement.pending.id!])
    }

    func testClassificationDoesNotKeepRemovedProcessAlive() async {
        let f = fixture(), reply = f.classifier.next()
        var process: RoutingProcess? = RoutingProcess()
        let isReleased = { [weak process] in process == nil }
        let task = f.notify(process!)
        await fulfillment(of: [reply.entered], timeout: 2)
        process = nil
        XCTAssertTrue(isReleased())
        reply.resolve(.success(true))
        await finish(task)
    }

    func testRepositoryRoutingReadsUnreadContextWithoutConsumingMessages() async throws {
        let f = fixture(), reply = f.classifier.next()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("routing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Offline routing bot")
        let message = try repository.sendUserMessage(conversationID: bot.conversation.id, body: "Pause the edits")
        let process = RoutingProcess(agent: bot.agent)
        let task = f.router.notify(process, repository: repository)
        XCTAssertEqual(process.notifications.count, 1)
        await fulfillment(of: [reply.entered], timeout: 2)
        XCTAssertEqual(f.classifier.contexts.first?.unreadMessages, ["Pause the edits"])
        reply.resolve(.success(true))
        await finish(task)
        XCTAssertEqual(process.promotions, [process.pending.id!])
        XCTAssertEqual(try repository.latestMessages(for: bot.agent.id).map(\.message.id), [message.id])
    }

    func testExpiredClassificationCannotBeatADelayedTimeoutCallback() async {
        var instant = ContinuousClock.now
        let f = fixture(now: { instant })
        f.classifier.respond = { _ in
            // Move past the deadline without giving the timeout callback actor
            // time. The result must be checked independently of that callback.
            instant = instant.advanced(by: .seconds(31))
            return true
        }
        await finish(f.notify())
        XCTAssertEqual(f.classifier.contexts.count, 1)
        XCTAssertTrue(f.process.promotions.isEmpty, "Elapsed deadlines must hold even before the timer callback runs")
        XCTAssertFalse(f.process.pending.isImmediate)
    }

    func testContextThatExhaustsDeadlineDoesNotStartClassification() async {
        var instant = ContinuousClock.now
        let f = fixture(now: { instant })
        f.classifier.respond = { _ in true }
        let task = f.router.notify(f.process) {
            instant = instant.advanced(by: .seconds(31))
            return RoutingFixture.context
        }
        await finish(task)
        XCTAssertTrue(f.classifier.contexts.isEmpty)
        XCTAssertFalse(f.process.pending.isImmediate)
    }

    private enum FixtureError: Error { case unavailable }
}
