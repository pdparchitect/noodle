import Foundation

/// Runs the jobs of the tasks that prefer it one at a time on the thread that asks, in the order they were queued, so calls made
/// at the same time interleave the same way on every run, with no sleeps and no timing.
final class StepExecutor: TaskExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [UnownedJob] = []

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        lock.withLock { jobs.append(job) }
    }

    /// Runs the queued jobs, and every job they queue, until each task has finished or waits for something only the test can give.
    func runUntilIdle() {
        while runNext() {}
    }

    /// Runs the job queued first; false when there was none.
    @discardableResult
    func runNext() -> Bool {
        guard let job = lock.withLock({ jobs.isEmpty ? nil : jobs.removeFirst() }) else { return false }
        job.runSynchronously(on: asUnownedTaskExecutor())
        return true
    }

    /// Starts the call as a task on this executor. Nothing runs until `runUntilIdle()`.
    func start<Value>(_ call: @escaping () async throws -> Value) -> StartedCall<Value> {
        let started = StartedCall<Value>()
        started.task = Task(executorPreference: self) {
            do { started.result = .success(try await call()) } catch { started.result = .failure(error) }
        }
        return started
    }
}

/// A call started on a `StepExecutor`, and how it ended once it has.
final class StartedCall<Value>: @unchecked Sendable {
    fileprivate(set) var task: Task<Void, Never>?
    fileprivate(set) var result: Result<Value, Error>?

    /// The call's value; throws its error, or `NotFinished` while it is still running or waiting.
    func value() throws -> Value {
        guard let result else { throw NotFinished() }
        return try result.get()
    }

    struct NotFinished: Error {}
}
