import XCTest
@testable import Noodle

@MainActor final class VoiceCaptureRecoveryTests: XCTestCase {
    // Driven serially: audio calls run on the recovery's queue while the test awaits.
    private final class Device: @unchecked Sendable {
        let audio = VoiceAudioQueue()
        var running = false
        var duration: TimeInterval = 0
        var starts = 0
        var stops = 0
        var polls = 0
        var failStarts = 0
        var advanceEvery = 1
        var onPoll: (() -> Void)?

        /// Teardown is posted to the audio queue; wait for it before asserting.
        func drain() async { try? await audio.run {} }

        @MainActor func recovery() -> VoiceCaptureRecovery {
            VoiceCaptureRecovery(audio: audio, activate: {
                self.starts += 1
                if self.starts <= self.failStarts { throw VoiceFailure("Transient audio format change") }
                self.running = true
            }, deactivate: {
                self.stops += 1
                self.running = false
            }, running: { self.running }, duration: { self.duration }, wait: {
                self.polls += 1
                self.onPoll?()
                if self.running, self.advanceEvery > 0, self.polls % self.advanceEvery == 0 {
                    self.duration += 0.1
                }
                await Task.yield()
            })
        }
    }

    func testConfigurationChangeImmediatelyAfterStartRecoversAutomatically() async throws {
        let device = Device()
        device.onPoll = { if device.polls == 1 { device.running = false } }
        let recovery = device.recovery()
        try await recovery.start()
        XCTAssertEqual(device.starts, 2)
        let isRunning = await recovery.isRunning
        XCTAssertTrue(isRunning)
        XCTAssertGreaterThan(device.duration, 0)
    }

    func testTransientStartErrorsAreRetriedWithoutResettingAudio() async throws {
        let device = Device()
        device.failStarts = 2
        device.duration = 7
        try await device.recovery().start()
        XCTAssertEqual(device.starts, 3)
        XCTAssertGreaterThan(device.duration, 7)
    }

    func testRunningEngineMustDeliverAudioBeforeStartupSucceeds() async throws {
        let device = Device()
        device.advanceEvery = 3 // Low-rate hardware can deliver a buffer every 300 ms.
        try await device.recovery().start()
        XCTAssertEqual(device.starts, 1)
        XCTAssertEqual(device.polls, 6)
    }

    func testLaterConfigurationChangeRecoversTheSameRecording() async throws {
        let device = Device()
        let recovery = device.recovery()
        try await recovery.start()
        let before = device.duration
        device.running = false
        try await recovery.start()
        XCTAssertEqual(device.starts, 2)
        XCTAssertGreaterThan(device.duration, before)
    }

    func testRunningButStalledInputHasBoundedRetriesAndNoSettingsAdvice() async {
        let device = Device()
        device.advanceEvery = 0
        let recovery = device.recovery()
        do {
            try await recovery.start()
            XCTFail("A running engine without audio must not count as recording")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("try recording again"))
            XCTAssertFalse(error.localizedDescription.contains("Settings"))
        }
        XCTAssertEqual(device.starts, 5)
        XCTAssertEqual(device.polls, 50)
        recovery.stop()
        await device.drain()
        XCTAssertFalse(device.running)
    }

    func testStopDuringPendingRecoveryCannotRestartTheMicrophone() async {
        let device = Device()
        let recovery = device.recovery()
        device.onPoll = { [weak recovery] in recovery?.stop() }
        do {
            try await recovery.start()
            XCTFail("A discarded recording must cancel pending recovery")
        } catch { XCTAssertTrue(error is CancellationError) }
        await device.drain()
        XCTAssertEqual(device.starts, 1)
        XCTAssertEqual(device.stops, 1)
        XCTAssertFalse(device.running)
    }

    func testMicrophoneCallsNeverRunOnTheMainThread() async {
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var total = 0
            private(set) var onMain = 0
            func record() {
                lock.lock(); defer { lock.unlock() }
                total += 1
                if Thread.isMainThread { onMain += 1 }
            }
        }
        let calls = Calls()
        let recovery = VoiceCaptureRecovery(activate: {
            calls.record()
            throw VoiceFailure("Transient audio format change")
        }, deactivate: { calls.record() }, running: {
            calls.record()
            return false
        }, duration: { 0 }, wait: { await Task.yield() })
        _ = try? await recovery.start()
        XCTAssertGreaterThan(calls.total, 0)
        // Core Audio can block indefinitely; a blocked call must not freeze the UI.
        XCTAssertEqual(calls.onMain, 0)
    }

    func testBlockedMicrophoneFailsInsteadOfHanging() async {
        final class Gate: @unchecked Sendable {
            let release = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var blocked = false
            var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
            func block() {
                lock.lock(); blocked = true; lock.unlock()
                release.wait()
            }
        }
        let gate = Gate()
        // The deadline expires only once a call is stuck, never on timing alone.
        let audio = VoiceAudioQueue(deadline: {
            while !gate.isBlocked { try await Task.sleep(for: .milliseconds(1)) }
        })
        let recovery = VoiceCaptureRecovery(audio: audio, activate: { gate.block() },
            deactivate: {}, running: { false }, duration: { 0 }, wait: { await Task.yield() })
        do {
            try await recovery.start()
            XCTFail("A blocked device must not count as recording")
        } catch { XCTAssertTrue(error is VoiceAudioQueue.Unresponsive) }
        // The queue is still blocked; later calls fail at once instead of queueing.
        do {
            _ = try await audio.run { true }
            XCTFail("A blocked queue must reject new calls")
        } catch { XCTAssertTrue(error is VoiceAudioQueue.Unresponsive) }
        gate.release.signal()
    }

    func testCancelledTaskNeverStartsMicrophone() async {
        let device = Device()
        let recovery = device.recovery()
        let task = Task { try await recovery.start() }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled startup must not open audio input")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(device.starts, 0)
    }
}
