// No microphone or real conversation is accessed. Optional --transcribe accepts
// a synthetic spoken fixture to exercise Apple's on-device speech engine.
import AppKit
import AVFoundation
import Speech
import NoodleCore

@main private enum VoiceRecordingTests {
    @MainActor static func main() async throws {
        guard #available(macOS 26.0, *) else { print("SKIP: macOS 26 required"); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-voice-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("recording.caf")
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
        precondition(abs(snapshot.duration - 1.024) < 0.04)
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
