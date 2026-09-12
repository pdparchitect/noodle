import Foundation
import NoodleCore
import XCTest
@testable import Noodle

/// Deliberately returns late answers after cancellation, like an external callback.
@MainActor final class RoutingGate<Value: Sendable> {
    let entered = XCTestExpectation(description: "routing dependency entered")
    let cancelled = XCTestExpectation(description: "routing dependency cancelled")
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func value() async throws -> Value {
        let cancelled = cancelled
        return try await withTaskCancellationHandler {
            entered.fulfill()
            return try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) }
                else { self.continuation = continuation }
            }
        } onCancel: { cancelled.fulfill() }
    }

    func resolve(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor final class RoutingClassifier: MessageDeliveryClassifying {
    var isAvailable = true
    private(set) var contexts: [MessageDeliveryContext] = []
    private var replies: [RoutingGate<Bool>] = []
    var respond: ((MessageDeliveryContext) async throws -> Bool)?

    func next() -> RoutingGate<Bool> {
        let gate = RoutingGate<Bool>()
        replies.append(gate)
        return gate
    }

    func shouldSendImmediately(_ context: MessageDeliveryContext) async throws -> Bool {
        let index = contexts.count
        contexts.append(context)
        if let respond { return try await respond(context) }
        guard replies.indices.contains(index) else {
            XCTFail("Unexpected classifier call")
            return false
        }
        return try await replies[index].value()
    }

    func releaseAll() {
        for reply in replies { reply.resolve(.failure(CancellationError())) }
    }
}

/// Only models the notification contract; never starts a process or loads a model.
@MainActor final class RoutingProcess: AgentRuntimeProcess {
    let configuration: AgentRecord
    var snapshot: AgentRuntimeSnapshot
    var isAlive = true
    var hasInterruptedWork = false
    var canReceiveHeartbeat = false
    var phaseAfterNotify: AgentRuntimePhase?
    private(set) var notifications: [(id: UUID, immediate: Bool)] = []
    private(set) var promotions: [UUID] = []
    var pending = PendingAgentNotification()

    init(agent: AgentRecord = AgentRecord(displayName: "Offline routing fixture"), phase: AgentRuntimePhase = .working) {
        configuration = agent
        snapshot = .init(agentID: agent.id, phase: phase, detail: "Fixture")
    }
    func notify(immediately: Bool) -> UUID {
        let id = pending.enqueue(immediately: immediately)
        notifications.append((id, immediately))
        if let phaseAfterNotify { snapshot.phase = phaseAfterNotify }
        return id
    }
    func promoteNotification(_ id: UUID) {
        promotions.append(id)
        pending.promote(id)
    }
    func start() { XCTFail("Routing must never start a harness") }
    func stop(completion: @escaping (Bool) -> Void) { XCTFail("Routing must never stop a harness") }
    func heartbeat() { XCTFail("Routing must not send a heartbeat") }
    func resolveApproval(_ approval: AgentApprovalRequest, allow: Bool, answers: [String: String]) {
        XCTFail("Routing must not resolve approvals")
    }
}

@MainActor final class RoutingFixture {
    let suite = "Noodle.MessageDeliveryRouterTests.\(UUID())"
    let defaults: UserDefaults
    let classifier = RoutingClassifier()
    let router: MessageDeliveryRouter
    let process = RoutingProcess()
    static let context = MessageDeliveryContext(unreadMessages: ["Pause those edits"], recentMessages: ["Assistant: editing files"])

    init(timeout: Duration, now: @escaping () -> ContinuousClock.Instant) {
        defaults = UserDefaults(suiteName: suite)!
        router = MessageDeliveryRouter(defaults: defaults, classifier: classifier, timeout: timeout, now: now)
    }
    func mode(_ mode: MessageDeliveryMode) { defaults.set(mode.rawValue, forKey: MessageDeliveryMode.defaultsKey) }
    func notify(_ process: RoutingProcess? = nil) -> Task<Void, Never>? {
        router.notify(process ?? self.process) { Self.context }
    }
    func cleanUp() {
        router.cancelAll()
        classifier.releaseAll()
        defaults.removePersistentDomain(forName: suite)
    }
}
