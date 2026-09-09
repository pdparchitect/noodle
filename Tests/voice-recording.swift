// No microphone or real conversation is accessed. Optional --transcribe accepts
// a synthetic spoken fixture to exercise Apple's on-device speech engine.
import AppKit
import AVFoundation
import Speech
import NoodleCore

@main private enum VoiceRecordingTests {
    @MainActor static func main() async throws {
        guard #available(macOS 26.0, *) else { print("SKIP: macOS 26 required"); return }
        if CommandLine.arguments.contains("--devices") {
            for device in VoiceInputDevice.available() {
                print("\(device.name)\(device.audioID == VoiceInputDevice.defaultDeviceID ? " (default)" : "")")
            }
            return
        }
        let devices = [VoiceInputDevice(id: "built-in", name: "Built-in", audioID: 10),
                       VoiceInputDevice(id: "usb", name: "USB", audioID: 20)]
        let defaultDevice = try VoiceInputDevice.resolve(uid: "", devices: devices, defaultID: 10)
        precondition(defaultDevice.id == "built-in")
        let selectedDevice = try VoiceInputDevice.resolve(uid: "usb", devices: devices, defaultID: 10)
        precondition(selectedDevice.audioID == 20)
        do {
            _ = try VoiceInputDevice.resolve(uid: "disconnected", devices: devices, defaultID: 10)
            preconditionFailure("Must not silently record a different microphone")
        } catch {}
        for interleaved in [false, true] {
            for commonFormat: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32] {
                let format = AVAudioFormat(commonFormat: commonFormat, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
                buffer.frameLength = 16
                for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    memset(audioBuffer.mData!, 0, Int(audioBuffer.mDataByteSize))
                }
                precondition(VoiceAudioSink.peak(buffer) == 0)
                let plane = interleaved ? 0 : 1
                let index = interleaved ? 7 : 3
                buffer.floatChannelData?[plane][index] = 0.5
                buffer.int16ChannelData?[plane][index] = 16_384
                buffer.int32ChannelData?[plane][index] = 1_073_741_824
                precondition(abs(VoiceAudioSink.peak(buffer) - 0.5) < 0.001, "Meter must see the second channel in each PCM format")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-voice-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("recording.caf")
        let integerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let integerStream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let integerSink = try VoiceAudioSink(url: directory.appendingPathComponent("integer.caf"),
            sourceFormat: integerFormat, targetFormat: integerFormat, continuation: integerStream.continuation)
        let integerBuffer = AVAudioPCMBuffer(pcmFormat: integerFormat, frameCapacity: 16_000)!
        integerBuffer.frameLength = 16_000
        for i in 0..<16_000 { integerBuffer.int16ChannelData![0][i] = 0 }
        for _ in 0..<4 { integerSink.consume(integerBuffer) }
        precondition(integerSink.snapshot().silentDuration >= 3)
        for i in 0..<16_000 { integerBuffer.int16ChannelData![0][i] = 16_384 }
        integerSink.consume(integerBuffer)
        precondition(integerSink.snapshot().silentDuration == 0)
        precondition(integerSink.snapshot().liveWaveform.count == 100)
        precondition(integerSink.snapshot().liveWaveform.prefix(80).allSatisfy { $0 == 0 })
        precondition(integerSink.snapshot().liveWaveform.suffix(20).allSatisfy { abs($0 - 0.5) < 0.001 })
        for _ in 0..<10 { integerSink.consume(integerBuffer) }
        precondition(integerSink.snapshot().liveWaveform.count == 240, "Live history must stay bounded")
        precondition((integerSink.snapshot().waveform.max() ?? 0) >= 0.49)
        integerSink.finish()
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--transcribe" {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), to: audio)
            let file = try AVAudioFile(forReading: audio)
            let voice = VoiceMessage(transcript: nil, duration: Double(file.length) / file.processingFormat.sampleRate,
                                     waveform: [], localeIdentifier: nil)
            try JSONEncoder().encode(VoiceRecordingDraft(voice: voice, transcriptionComplete: false))
                .write(to: directory.appendingPathComponent("draft.json"))
            let recorder = VoiceRecorder(directory: directory)
            await recorder.retry()
            guard recorder.phase == .ready, let transcript = recorder.metadata.transcript else {
                throw VoiceFailure(recorder.error ?? "Native transcription did not complete")
            }
            print("Native transcription: \(transcript)")
            guard transcript.lowercased().contains("voice"), transcript.lowercased().contains("message") else {
                throw VoiceFailure("Expected synthetic fixture words were not transcribed")
            }
            let restored = VoiceRecorder(directory: directory)
            precondition(restored.phase == .ready && restored.metadata.transcript == transcript)
            print("PASS: native transcription, finalization and completed draft restoration")

            // Exercise the same conversion/stream/finalization path as live mic
            // capture, feeding a file instead of accessing a microphone.
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)!
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])!
            let liveFile = try AVAudioFile(forReading: audio)
            let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64))
            let sink = try VoiceAudioSink(url: directory.appendingPathComponent("live.caf"),
                sourceFormat: liveFile.processingFormat, targetFormat: format, continuation: stream.continuation)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let text = Task { () throws -> String in
                var parts: [String] = []
                for try await result in transcriber.results where result.isFinal { parts.append(String(result.text.characters)) }
                return parts.joined(separator: " ")
            }
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream.stream)
            while liveFile.framePosition < liveFile.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: liveFile.processingFormat, frameCapacity: 4096)!
                try liveFile.read(into: buffer)
                sink.consume(buffer)
            }
            sink.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let liveText = try await text.value
            precondition(liveText.lowercased().contains("voice message"), liveText)
            precondition(sink.snapshot().error == nil)
            print("PASS: live-buffer transcription: \(liveText)")
            return
        }

        let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let sink = try VoiceAudioSink(url: audio, sourceFormat: source, targetFormat: target, continuation: stream.continuation)
        for _ in 0..<12 {
            let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4096)!
            buffer.frameLength = 4096
            for channel in 0..<2 {
                for i in 0..<4096 { buffer.floatChannelData![channel][i] = 0.25 * sin(Float(i) * 0.1) }
            }
            sink.consume(buffer)
        }
        sink.finish()
        let snapshot = sink.snapshot()
        precondition(snapshot.error == nil, snapshot.error ?? "")
        precondition(snapshot.silentDuration == 0 && (snapshot.waveform.max() ?? 0) > 0.1)
        precondition(abs(snapshot.duration - 1.024) < 0.04)
        precondition(snapshot.liveWaveform.count == Int(snapshot.duration / 0.05), "Live bars must follow audio time, not callback count")
        precondition(!snapshot.waveform.isEmpty && snapshot.waveform.allSatisfy { (0...1).contains($0) })
        let recorded = try AVAudioFile(forReading: audio)
        precondition(recorded.length > 15_000 && recorded.processingFormat.sampleRate == 16_000)
        let metadata = VoiceMessage(transcript: "unfinished guess", duration: snapshot.duration,
                                    waveform: snapshot.waveform, localeIdentifier: "en-GB")
        try JSONEncoder().encode(VoiceRecordingDraft(voice: metadata, transcriptionComplete: false))
            .write(to: directory.appendingPathComponent("draft.json"))
        let interrupted = VoiceRecorder(directory: directory)
        precondition(interrupted.hasAudio && interrupted.phase == .failed && interrupted.transcript == nil,
                     "Incomplete speech must not be restored as a finalized transcript")
        try JSONEncoder().encode(VoiceRecordingDraft(voice: metadata, transcriptionComplete: true))
            .write(to: directory.appendingPathComponent("draft.json"))
        let finished = VoiceRecorder(directory: directory)
        precondition(finished.phase == .ready && finished.transcript == "unfinished guess")
        let sentinel = directory.appendingPathComponent("unrelated.txt")
        try Data("retain".utf8).write(to: sentinel)
        await finished.discard()
        precondition(finished.phase == .idle && !finished.hasAudio)
        precondition(FileManager.default.fileExists(atPath: sentinel.path))
        print("PASS: capture conversion, preserved audio, waveform, interrupted/completed draft restoration, scoped discard")
    }
}
