import Foundation

/// Hardware configuration changes can stop AVAudioEngine immediately after a
/// successful start. Require advancing buffers and retry the same capture so a
/// pending route change can settle without selecting the device again.
@MainActor final class VoiceCaptureRecovery {
    private let activate: () throws -> Void
    private let deactivate: () -> Void
    private let running: () -> Bool
    private let duration: () -> TimeInterval
    private let failure: () -> String?
    private let wait: () async throws -> Void
    private var generation = UUID()

    var isRunning: Bool { running() }

    init(activate: @escaping () throws -> Void, deactivate: @escaping () -> Void,
         running: @escaping () -> Bool, duration: @escaping () -> TimeInterval,
         failure: @escaping () -> String? = { nil },
         wait: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }) {
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
            if !running() || stalled >= 10 {
                guard attempts < 5 else { throw StartupFailure() }
                if running() { deactivate() }
                attempts += 1
                do { try activate() } catch { /* A changing route can reject a start temporarily. */ }
                previous = duration()
                advancing = 0
                stalled = 0
            }
            try await wait()
            try check(token)
            let current = duration()
            if running(), current > previous {
                advancing += 1
                if advancing >= 2 { return }
            } else if !running() {
                advancing = 0
            }
            stalled = current > previous ? 0 : stalled + 1
            previous = current
        }
        throw StartupFailure()
    }

    func stop() {
        generation = UUID()
        deactivate()
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private struct StartupFailure: LocalizedError {
        var errorDescription: String? { "The microphone didn’t start responding. Please try recording again." }
    }
}
