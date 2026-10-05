import AVFoundation
@testable import NoodleMobile
import Speech
import Testing

@MainActor @Suite struct VoiceRecorderTests {
    @Test func discardingAnIdleRecorderDoesNotDeactivateAnotherCallsAudio() async {
        var deactivations = 0
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = VoiceRecorder(directory: directory, deactivateAudioSession: { deactivations += 1 })
        await recorder.discard()
        #expect(deactivations == 0, "An idle recorder never owned the call's audio session")
    }

    // The engine delivers tapped audio on its own thread, never on the main actor.
    @Test func theMicrophoneTapRunsOffTheMainActor() async throws {
        let source = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let sink = try VoiceAudioSink(url: url, targetFormat: target, continuation: stream.continuation)

        // Offline before the mixer is first touched, so the engine never wires up the simulator's audio device.
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: source, maximumFrameCount: 4096)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: source)
        VoiceRecorder.tap(engine.mainMixerNode, into: sink)
        let sound = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 16_000))
        sound.frameLength = 16_000
        player.scheduleBuffer(sound, completionHandler: nil)
        try engine.start()
        player.play()
        let output = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4096))
        for _ in 0..<4 { _ = try engine.renderOffline(4096, to: output) }
        for _ in 0..<50 where sink.snapshot().duration == 0 { try await Task.sleep(for: .milliseconds(20)) }
        engine.stop()
        sink.finish()
        #expect(sink.snapshot().duration > 0)
    }

    // Audio arrives in uneven chunks; the meter still moves the same distance every frame.
    @Test func theLiveMeterScrollsAtAnEvenPaceBetweenChunks() {
        let frame = 1.0 / 60
        var positions: [Double] = []
        for step in 60..<120 {
            let elapsed = Double(step) * frame
            // Whole 4096-frame buffers at 48 kHz, read every 100 ms: the samples the view has lag and jump.
            let polled = (elapsed / 0.1).rounded(.down) * 0.1
            let delivered = (polled * 48_000 / 4096).rounded(.down) * 4096 / 48_000
            positions.append(LiveVoiceWaveform.position(elapsed: elapsed, sampleCount: Int(delivered / 0.05)))
        }
        let steps = zip(positions.dropFirst(), positions).map { $0 - $1 }
        #expect(steps.allSatisfy { abs($0 - frame / 0.05) < 0.000001 })
    }

    @Test func theLiveMeterNeverRunsAheadOfTheAudio() {
        #expect(LiveVoiceWaveform.position(elapsed: 5, sampleCount: 20) == 20)
    }
}
