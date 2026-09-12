import AVFoundation
import NoodleAudioCapture
import Speech
import XCTest
@testable import Noodle

/// Hardware-free regression coverage: manual rendering never opens a microphone.
@available(macOS 26.0, *)
@MainActor final class VoiceCaptureTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-voice-capture-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func buffer(rate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = 0.25 }
        }
        return buffer
    }

    private func engine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let input = buffer(rate: 48_000, channels: 2, frames: 4096)
        try engine.enableManualRenderingMode(.offline, format: input.format, maximumFrameCount: 4096)
        XCTAssertTrue(engine.inputNode.setManualRenderingInputPCMFormat(input.format) { _ in input.audioBufferList })
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: input.format)
        return engine
    }

    func testTapStartsStopsAndRestartsWithoutOpeningHardware() throws {
        let engine = try engine()
        let capture = NoodleAudioCapture(engine: engine)
        for _ in 0..<3 {
            try capture.start(withBufferSize: 4096) { _, _ in }
            XCTAssertTrue(engine.isRunning)
            let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
            XCTAssertEqual(try engine.renderOffline(4096, to: output), .success)
            capture.stop()
            capture.stop()
            XCTAssertFalse(engine.isRunning)
        }
    }

    func testNativeTapExceptionBecomesRecoverableSwiftError() throws {
        let engine = try engine()
        // AVFAudio throws an Objective-C exception for a second tap. Swift's
        // do/catch alone cannot contain it; exercise the same native boundary
        // that handles the production device-format exception.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { _, _ in }
        let capture = NoodleAudioCapture(engine: engine)
        XCTAssertThrowsError(try capture.start(withBufferSize: 4096) { _, _ in }) { error in
            XCTAssertEqual((error as NSError).domain, "NoodleAudioCapture")
            XCTAssertTrue(error.localizedDescription.contains("microphone"))
        }
        capture.stop() // Must not remove the tap owned by the fixture.
        engine.inputNode.removeTap(onBus: 0)
        try capture.start(withBufferSize: 4096) { _, _ in }
        XCTAssertTrue(engine.isRunning, "A failed attempt must allow recording to be retried")
        capture.stop()
    }

    func testTapReplacesStaleOutputFormatWithCurrentInputFormat() throws {
        let engine = try engine()
        let stale = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        // Manual input supports conversion, so it can model the mismatched
        // scopes seen in the crash without accessing or reconfiguring hardware.
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: stale)
        XCTAssertEqual(engine.inputNode.outputFormat(forBus: 0).sampleRate, 16_000)
        XCTAssertEqual(engine.inputNode.inputFormat(forBus: 0).sampleRate, 48_000)
        let capture = NoodleAudioCapture(engine: engine)
        try capture.start(withBufferSize: 4096) { _, _ in }
        defer { capture.stop() }
        XCTAssertEqual(engine.inputNode.outputFormat(forBus: 0).sampleRate, 48_000)
        XCTAssertEqual(engine.inputNode.outputFormat(forBus: 0).channelCount, 2)
    }

    func testCaptureReleaseStopsItsOwnedTap() throws {
        let engine = try engine()
        var capture: NoodleAudioCapture? = NoodleAudioCapture(engine: engine)
        try capture?.start(withBufferSize: 4096) { _, _ in }
        XCTAssertTrue(engine.isRunning)
        capture = nil
        XCTAssertFalse(engine.isRunning)
    }

    func testConverterFollowsDeliveredFormatAcrossMicrophoneChanges() throws {
        let url = try directory().appendingPathComponent("recording.caf")
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let sink = try VoiceAudioSink(url: url, targetFormat: target, continuation: stream.continuation)
        // Reproduce the production transition from 16 kHz mono to 48 kHz stereo.
        sink.consume(buffer(rate: 16_000, channels: 1, frames: 16_000))
        sink.consume(buffer(rate: 48_000, channels: 2, frames: 48_000))
        sink.finish()
        let result = sink.snapshot()
        XCTAssertNil(result.error)
        // A newly created sample-rate converter retains a short priming tail.
        XCTAssertEqual(result.duration, 2, accuracy: 0.1)
        XCTAssertGreaterThan(result.waveform.max() ?? 0, 0.2)
        let saved = try AVAudioFile(forReading: url)
        XCTAssertEqual(saved.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(saved.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(saved.length) / 16_000, result.duration, accuracy: 0.001)
    }

    func testDiscardBeforeStartupRunsKeepsTheRecorderIdle() async throws {
        let directory = try directory()
        let recorder = VoiceRecorder(directory: directory)
        recorder.start()
        XCTAssertEqual(recorder.phase, .preparing)
        await recorder.discard()
        await recorder.discard()
        // Let the cancelled preparation task run its cancellation check.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertNil(recorder.error)
        XCTAssertFalse(recorder.hasAudio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.audioURL.path))
    }
}
