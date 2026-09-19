import Foundation
import NoodleCore
import os

/// Queue immediately, then optionally promote that same pending wake. Inference
/// never blocks an idle agent or the normal end-of-turn delivery path.
/// The deadline only bounds a stuck model; it must outlast a cold model load,
/// and a verdict for an already dispatched wake promotes nothing.
@MainActor
final class MessageDeliveryRouter {
    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
        let timeout: Task<Void, Never>
    }
    private static let logger = Logger(subsystem: RuntimeDiagnostics.subsystem, category: "delivery")
    private var jobs: [UUID: Job] = [:]
    private let defaults: UserDefaults
    private let classifier: any MessageDeliveryClassifying
    private let timeout: Duration
    private let now: () -> ContinuousClock.Instant

    init(defaults: UserDefaults, classifier: any MessageDeliveryClassifying = MessageDeliveryClassifier(),
         timeout: Duration = .seconds(60), now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.defaults = defaults
        self.classifier = classifier
        self.timeout = timeout
        self.now = now
    }

    @discardableResult
    func notify(_ process: any AgentRuntimeProcess, repository: WorkspaceRepository) -> Task<Void, Never>? {
        let agentID = process.configuration.id
        return notify(process) { try await Task.detached {
            try MessageDeliveryContext.load(for: agentID, repository: repository)
        }.value }
    }

    @discardableResult
    func notify(_ process: any AgentRuntimeProcess,
                context: @escaping @MainActor () async throws -> MessageDeliveryContext?) -> Task<Void, Never>? {
        let agentID = process.configuration.id
        cancel(for: agentID)
        let mode = MessageDeliveryMode.load(from: defaults)
        let wasWorking = process.snapshot.phase == .working
        let notificationID = process.notify(immediately: mode == .immediate)
        guard mode == .automatic, wasWorking, classifier.isAvailable else { return nil }
        let jobID = UUID()
        let started = ContinuousClock.now
        let deadline = now().advanced(by: timeout)
        let task = Task { [weak self, weak process] in
            guard let self else { return }
            defer { self.finish(agentID: agentID, jobID: jobID) }
            do {
                // Check elapsed time as well as cancellation: the timeout task
                // may not get actor time before a late dependency returns.
                guard !Task.isCancelled, self.now() < deadline,
                      let context = try await context(),
                      !Task.isCancelled, self.now() < deadline else { return }
                let immediate = try await self.classifier.shouldSendImmediately(context)
                guard !Task.isCancelled, self.now() < deadline else {
                    // A newer message supersedes silently; only a missed deadline is notable.
                    guard self.now() >= deadline else { return }
                    Self.logger.notice("delivery-classification-expired bot=\(agentID.uuidString, privacy: .public) elapsed=\(started.duration(to: .now).description, privacy: .public)")
                    return
                }
                Self.logger.notice("delivery-classified bot=\(agentID.uuidString, privacy: .public) immediate=\(immediate) elapsed=\(started.duration(to: .now).description, privacy: .public)")
                guard immediate, MessageDeliveryMode.load(from: self.defaults) == .automatic else { return }
                process?.promoteNotification(notificationID)
            } catch {
                // The notification is already queued. The deadline cancels the
                // model call, so a missed deadline usually surfaces here.
                guard !Task.isCancelled else {
                    guard self.now() >= deadline else { return }
                    Self.logger.notice("delivery-classification-expired bot=\(agentID.uuidString, privacy: .public) elapsed=\(started.duration(to: .now).description, privacy: .public)")
                    return
                }
                Self.logger.error("delivery-classification-failed bot=\(agentID.uuidString, privacy: .public) elapsed=\(started.duration(to: .now).description, privacy: .public)")
            }
        }
        let timeout = Task { [now] in
            do { try await Task.sleep(for: max(.zero, now().duration(to: deadline))) } catch { return }
            task.cancel()
        }
        jobs[agentID] = Job(id: jobID, task: task, timeout: timeout)
        return task
    }

    func cancel(for agentID: UUID) {
        guard let job = jobs.removeValue(forKey: agentID) else { return }
        job.task.cancel(); job.timeout.cancel()
    }
    func cancelAll() {
        for id in Array(jobs.keys) { cancel(for: id) }
    }
    private func finish(agentID: UUID, jobID: UUID) {
        guard jobs[agentID]?.id == jobID else { return }
        jobs.removeValue(forKey: agentID)?.timeout.cancel()
    }
}
