import Foundation
import NoodleCore

/// Queue immediately, then optionally promote that same pending wake. Inference
/// never blocks an idle agent or the normal end-of-turn delivery path.
@MainActor
final class MessageDeliveryRouter {
    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
        let timeout: Task<Void, Never>
    }
    private var jobs: [UUID: Job] = [:]
    private let defaults: UserDefaults
    private let classifier: any MessageDeliveryClassifying
    private let timeout: Duration
    private let now: () -> ContinuousClock.Instant

    init(defaults: UserDefaults, classifier: any MessageDeliveryClassifying = MessageDeliveryClassifier(),
         timeout: Duration = .seconds(10), now: @escaping () -> ContinuousClock.Instant = { .now }) {
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
                guard !Task.isCancelled, self.now() < deadline, immediate,
                      MessageDeliveryMode.load(from: self.defaults) == .automatic else { return }
                process?.promoteNotification(notificationID)
            } catch { /* The notification is already queued. */ }
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
