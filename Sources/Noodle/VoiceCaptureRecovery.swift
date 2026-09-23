import Foundation

/// Hardware configuration changes can stop AVAudioEngine immediately after a
/// successful start. Require advancing buffers and retry the same capture so a
/// pending route change can settle without selecting the device again.
@MainActor final class VoiceCaptureRecovery {
    private let audio: VoiceAudioQueue
    private let activate: @Sendable () throws -> Void
    private let deactivate: @Sendable () -> Void
    private let running: @Sendable () -> Bool
    private let duration: () -> TimeInterval
    private let failure: () -> String?
    private let wait: () async throws -> Void
    private var generation = UUID()

    var isRunning: Bool { get async { (try? await audio.run(running)) ?? false } }

    init(audio: VoiceAudioQueue = VoiceAudioQueue(),
         activate: @escaping @Sendable () throws -> Void, deactivate: @escaping @Sendable () -> Void,
         running: @escaping @Sendable () -> Bool, duration: @escaping () -> TimeInterval,
         failure: @escaping () -> String? = { nil },
         wait: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }) {
        self.audio = audio
        self.activate = activate
        self.deactivate = deactivate
        self.running = running
        self.duration = duration
        self.failure = failure
        self.wait = wait
    }

    func start() async throws {
        let token = generation
        var previous = duration()
        var advancing = 0
        var stalled = 0
        var attempts = 0
        // At most five starts and five seconds of waiting, including a running
        // engine that never delivers buffers. Silence still advances duration.
        for _ in 0..<50 {
            try check(token)
            if let error = failure() { throw VoiceFailure(error) }
            var isRunning = try await audio.run(running)
            try check(token)
            if !isRunning || stalled >= 10 {
                guard attempts < 5 else { throw StartupFailure() }
                attempts += 1
                let activate = activate, deactivate = deactivate, wasRunning = isRunning
                do {
                    try await audio.run {
                        if wasRunning { deactivate() }
                        try activate()
                    }
                } catch let error as VoiceAudioQueue.Unresponsive {
                    throw error
                } catch { /* A changing route can reject a start temporarily. */ }
                try check(token)
                previous = duration()
                advancing = 0
                stalled = 0
            }
            try await wait()
            try check(token)
            isRunning = try await audio.run(running)
            try check(token)
            let current = duration()
            if isRunning, current > previous {
                advancing += 1
                if advancing >= 2 { return }
            } else if !isRunning {
                advancing = 0
            }
            stalled = current > previous ? 0 : stalled + 1
            previous = current
        }
        throw StartupFailure()
    }

    func stop() {
        generation = UUID()
        audio.post(deactivate)
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private struct StartupFailure: LocalizedError {
        var errorDescription: String? { "The microphone didn’t start responding. Please try recording again." }
    }
}

/// Core Audio calls can block indefinitely, for example on a stale aggregate
/// device after a USB microphone re-enumerates. Every engine call runs on this
/// serial queue; callers only wait until the deadline. A call that misses it
/// leaves the queue blocked, so later calls fail at once instead of queueing.
final class VoiceAudioQueue: @unchecked Sendable {
    struct Unresponsive: LocalizedError {
        var errorDescription: String? {
            "The microphone isn’t responding. Reconnect it or choose another in Settings → Chat."
        }
    }

    private let queue = DispatchQueue(label: "Noodle.voice-audio")
    private let deadline: @Sendable () async throws -> Void
    private let lock = NSLock()
    private var unresponsive = false

    init(deadline: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) {
        self.deadline = deadline
    }

    func run<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        guard !isUnresponsive else { throw Unresponsive() }
        let call = Call<T>()
        return try await withCheckedThrowingContinuation { continuation in
            call.begin(continuation)
            let timer = Task { [deadline] in
                do { try await deadline() } catch { return }
                if call.finish(.failure(Unresponsive())) { self.markUnresponsive() }
            }
            queue.async {
                let result = Result { try work() }
                timer.cancel()
                call.finish(result)
            }
        }
    }

    /// Fire-and-forget teardown that never waits on a blocked device.
    func post(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    private var isUnresponsive: Bool {
        lock.lock(); defer { lock.unlock() }
        return unresponsive
    }

    private func markUnresponsive() {
        lock.lock(); defer { lock.unlock() }
        unresponsive = true
    }

    private final class Call<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        func begin(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock(); defer { lock.unlock() }
            self.continuation = continuation
        }

        @discardableResult func finish(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            return continuation != nil
        }
    }
}
