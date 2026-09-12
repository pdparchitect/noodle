import XCTest
@testable import Noodle

@MainActor final class VoiceCaptureRecoveryTests: XCTestCase {
    @MainActor private final class Device {
        var running = false
        var duration: TimeInterval = 0
        var starts = 0
        var stops = 0
        var polls = 0
        var failStarts = 0
        var advanceEvery = 1
        var onPoll: (() -> Void)?

        func recovery() -> VoiceCaptureRecovery {
            VoiceCaptureRecovery(activate: {
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
        XCTAssertTrue(recovery.isRunning)
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
        XCTAssertEqual(device.starts, 1)
        XCTAssertEqual(device.stops, 1)
        XCTAssertFalse(device.running)
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
