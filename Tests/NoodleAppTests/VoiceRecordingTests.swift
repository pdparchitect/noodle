import AVFoundation
import Speech
import XCTest
import NoodleCore
@testable import Noodle

/// Recording without a microphone: buffers are made in memory and drafts are written by hand.
@available(macOS 26.0, *)
@MainActor final class VoiceRecordingTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-voice-recording-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The chosen microphone, or the system default when none is chosen. A chosen one that is gone is an
    /// error: recording from a different microphone without saying so is worse than not recording.
    func testMicrophoneIsTheChosenOneOrTheDefaultButNeverASubstitute() throws {
        let devices = [VoiceInputDevice(id: "built-in", name: "Built-in", audioID: 10),
                       VoiceInputDevice(id: "usb", name: "USB", audioID: 20)]
        XCTAssertEqual(try VoiceInputDevice.resolve(uid: "", devices: devices, defaultID: 10).id, "built-in")
        XCTAssertEqual(try VoiceInputDevice.resolve(uid: "usb", devices: devices, defaultID: 10).audioID, 20)
        XCTAssertThrowsError(try VoiceInputDevice.resolve(uid: "disconnected", devices: devices, defaultID: 10))
    }

    /// The level meter reads every channel, in each PCM format and layout a microphone may deliver.
    func testLevelMeterReadsTheSecondChannelInEveryFormat() throws {
        for interleaved in [false, true] {
            for commonFormat: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32] {
                let format = try XCTUnwrap(AVAudioFormat(commonFormat: commonFormat, sampleRate: 48_000, channels: 2,
                                                         interleaved: interleaved))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
                buffer.frameLength = 16
                for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    memset(audioBuffer.mData!, 0, Int(audioBuffer.mDataByteSize))
                }
                XCTAssertEqual(VoiceAudioSink.peak(buffer), 0)
                let plane = interleaved ? 0 : 1, index = interleaved ? 7 : 3
                buffer.floatChannelData?[plane][index] = 0.5
                buffer.int16ChannelData?[plane][index] = 16_384
                buffer.int32ChannelData?[plane][index] = 1_073_741_824
                XCTAssertEqual(VoiceAudioSink.peak(buffer), 0.5, accuracy: 0.001, "\(commonFormat.rawValue) interleaved: \(interleaved)")
            }
        }
    }

    /// Silence is measured in audio time, the live waveform keeps the latest 240 bars, and there is one
    /// live bar per 50 ms of audio, however the audio arrives.
    func testSilenceAndLiveWaveformFollowAudioTime() throws {
        let folder = try directory()
        // Speech analysis takes 16-bit input on macOS 27; a Float32 target traps there.
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let sink = try VoiceAudioSink(url: folder.appendingPathComponent("integer.caf"), targetFormat: format,
                                      continuation: stream.continuation)
        let second = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        second.frameLength = 16_000
        for i in 0..<16_000 { second.int16ChannelData![0][i] = 0 }
        for _ in 0..<4 { sink.consume(second) }
        XCTAssertGreaterThanOrEqual(sink.snapshot().silentDuration, 3)
        for i in 0..<16_000 { second.int16ChannelData![0][i] = 16_384 }
        sink.consume(second)
        XCTAssertEqual(sink.snapshot().silentDuration, 0)
        XCTAssertEqual(sink.snapshot().liveWaveform.count, 100)
        XCTAssertTrue(sink.snapshot().liveWaveform.prefix(80).allSatisfy { $0 == 0 })
        XCTAssertTrue(sink.snapshot().liveWaveform.suffix(20).allSatisfy { abs($0 - 0.5) < 0.001 })
        for _ in 0..<10 { sink.consume(second) }
        XCTAssertEqual(sink.snapshot().liveWaveform.count, 240, "Live history stays bounded")
        XCTAssertGreaterThanOrEqual(sink.snapshot().waveform.max() ?? 0, 0.49)
        sink.finish()

        // Stereo 48 kHz in small callbacks: the bar count still follows the audio's length.
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let converted = try VoiceAudioSink(url: folder.appendingPathComponent("converted.caf"), targetFormat: format,
                                           continuation: AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64)).continuation)
        for _ in 0..<12 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4096))
            buffer.frameLength = 4096
            for channel in 0..<2 {
                for i in 0..<4096 { buffer.floatChannelData![channel][i] = 0.25 * sin(Float(i) * 0.1) }
            }
            converted.consume(buffer)
        }
        converted.finish()
        let snapshot = converted.snapshot()
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.duration, 1.024, accuracy: 0.04)
        XCTAssertEqual(snapshot.liveWaveform.count, Int(snapshot.duration / 0.05))
        XCTAssertTrue(snapshot.waveform.allSatisfy { (0...1).contains($0) })
    }

    /// A draft whose transcription never finished comes back as failed with its audio kept, not as a
    /// finished transcript. Discarding removes the recording's own files and nothing else in the folder.
    func testDraftsRestoreHonestlyAndDiscardRemovesOnlyTheRecording() async throws {
        let folder = try directory()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let sink = try VoiceAudioSink(url: folder.appendingPathComponent("recording.caf"), targetFormat: format,
                                      continuation: AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64)).continuation)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.int16ChannelData![0][i] = 8_000 }
        sink.consume(buffer)
        sink.finish()
        let snapshot = sink.snapshot()
        let voice = VoiceMessage(transcript: "unfinished guess", duration: snapshot.duration,
                                 waveform: snapshot.waveform, localeIdentifier: "en-GB")
        let draft = folder.appendingPathComponent("draft.json")
        try JSONEncoder().encode(VoiceRecordingDraft(voice: voice, transcriptionComplete: false)).write(to: draft)
        let interrupted = VoiceRecorder(directory: folder)
        XCTAssertTrue(interrupted.hasAudio)
        XCTAssertEqual(interrupted.phase, .failed)
        XCTAssertNil(interrupted.transcript)

        try JSONEncoder().encode(VoiceRecordingDraft(voice: voice, transcriptionComplete: true)).write(to: draft)
        let finished = VoiceRecorder(directory: folder)
        XCTAssertEqual(finished.phase, .ready)
        XCTAssertEqual(finished.transcript, "unfinished guess")
        let unrelated = folder.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        await finished.discard()
        XCTAssertEqual(finished.phase, .idle)
        XCTAssertFalse(finished.hasAudio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
