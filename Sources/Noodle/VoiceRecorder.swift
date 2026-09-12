import AppKit
import AVFoundation
import Speech
import Observation
import NoodleCore
import NoodleAudioCapture

struct VoiceRecordingDraft: Codable {
    let voice: VoiceMessage
    let transcriptionComplete: Bool
}

@available(macOS 26.0, *)
@MainActor @Observable final class VoiceRecorder {
    enum Phase { case idle, preparing, recording, finishing, ready, failed }
    private(set) var phase: Phase = .idle
    private(set) var duration: TimeInterval = 0
    private(set) var levels: [Float] = []
    private(set) var liveLevels: [Float] = []
    private(set) var transcript: String?
    private(set) var error: String?
    private(set) var preparation = "Preparing speech…"
    private(set) var inputName = "Microphone"
    private(set) var noInputSignal = false
    private(set) var recoveringInput = false
    let directory: URL
    var audioURL: URL { directory.appendingPathComponent("recording.caf") }
    var hasAudio: Bool { duration > 0 && FileManager.default.fileExists(atPath: audioURL.path) }
    var metadata: VoiceMessage { .init(transcript: transcript, duration: duration, waveform: levels, localeIdentifier: localeIdentifier) }

    private var localeIdentifier: String?
    private var capture: VoiceCaptureRecovery?
    private var sink: VoiceAudioSink?
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var generation = UUID()
    private var recognitionError: String?

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("draft.json")),
           let saved = try? JSONDecoder().decode(VoiceRecordingDraft.self, from: data),
           FileManager.default.fileExists(atPath: audioURL.path) {
            duration = saved.voice.duration
            levels = saved.voice.waveform
            transcript = saved.transcriptionComplete ? saved.voice.transcript : nil
            localeIdentifier = saved.voice.localeIdentifier
            if let file = try? AVAudioFile(forReading: audioURL), file.processingFormat.sampleRate > 0 {
                duration = Double(file.length) / file.processingFormat.sampleRate
            }
            phase = transcript == nil ? .failed : .ready
            if transcript == nil { error = "Recording preserved. Retry transcription or send audio only." }
        }
    }

    func start() {
        guard phase == .idle else { return }
        phase = .preparing
        error = nil
        noInputSignal = false
        recoveringInput = false
        let token = UUID()
        generation = token
        preparationTask = Task {
            do {
                try check(token)
                let transcriber = try await prepareTranscriber(token: token)
                try check(token)
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw VoiceFailure("Microphone access is off. Enable Noodle in System Settings → Privacy & Security → Microphone.")
                }
                try check(token)
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    throw VoiceFailure("No supported microphone format is available.")
                }
                try check(token)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64))
                let sink = try VoiceAudioSink(url: audioURL, targetFormat: format,
                                             continuation: stream.continuation)
                self.sink = sink
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                self.analyzer = analyzer
                listen(to: transcriber, token: token)
                try await analyzer.prepareToAnalyze(in: format)
                try check(token)
                try await analyzer.start(inputSequence: stream.stream)
                try check(token)
                let engine = AVAudioEngine()
                inputName = try VoiceInputDevice.configure(engine).name
                let nativeCapture = NoodleAudioCapture(engine: engine)
                let capture = VoiceCaptureRecovery(
                    activate: { try nativeCapture.start(withBufferSize: 4096) { buffer, _ in sink.consume(buffer) } },
                    deactivate: { nativeCapture.stop() },
                    running: { nativeCapture.isRunning },
                    duration: { sink.snapshot().duration },
                    failure: { sink.snapshot().error })
                self.capture = capture
                try await capture.start()
                try check(token)
                phase = .recording
                try persist()
                meterTask = Task {
                    var ticks = 0
                    var stalledTicks = 0
                    var previousDuration: Double = 0
                    while !Task.isCancelled && phase == .recording {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled, generation == token, phase == .recording else { break }
                        let snapshot = sink.snapshot()
                        duration = snapshot.duration
                        levels = snapshot.waveform
                        liveLevels = snapshot.liveWaveform
                        ticks += 1
                        stalledTicks = snapshot.duration == previousDuration ? stalledTicks + 1 : 0
                        previousDuration = snapshot.duration
                        noInputSignal = snapshot.silentDuration >= 3 && capture.isRunning && stalledTicks < 10
                        if snapshot.error == nil, !capture.isRunning || stalledTicks >= 10 {
                            recoveringInput = true
                            noInputSignal = false
                            do {
                                try await capture.start()
                                try check(token)
                                guard phase == .recording else { break }
                                recoveringInput = false
                                stalledTicks = 0
                                previousDuration = sink.snapshot().duration
                            } catch {
                                guard generation == token, phase == .recording else { break }
                                recoveringInput = false
                                await stopEngineAndAnalysis()
                                guard generation == token, phase == .recording else { break }
                                transcript = nil
                                self.error = "The microphone stopped responding. Your audio is preserved; retry transcription or send audio only."
                                phase = .failed
                                try? persist()
                                break
                            }
                        }
                        if ticks % 10 == 0 { try? persist() }
                        if snapshot.error != nil || duration >= 600 {
                            // Finish outside the meter task: finish cancels this task.
                            Task { await finish() }
                            break
                        }
                    }
                }
            } catch {
                guard generation == token else { return }
                await stopEngineAndAnalysis()
                guard generation == token else { return }
                self.error = error.localizedDescription
                phase = .failed
            }
        }
    }

    private func prepareTranscriber(token: UUID) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw VoiceFailure("On-device transcription isn’t available for this Mac or its current language.")
        }
        try check(token)
        localeIdentifier = locale.identifier
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try check(token)
            preparation = "Downloading speech model…"
            try await request.downloadAndInstall()
        }
        try check(token)
        preparation = "Starting microphone…"
        return transcriber
    }

    private func listen(to transcriber: SpeechTranscriber, token: UUID) {
        recognitionError = nil
        results = Task {
            var finalized: [String] = []
            do {
                for try await result in transcriber.results {
                    guard generation == token else { return }
                    let text = String(result.text.characters)
                    if result.isFinal { finalized.append(text) }
                    transcript = (finalized + (result.isFinal ? [] : [text])).joined(separator: " ")
                }
                if generation == token { transcript = finalized.joined(separator: " ") }
            } catch {
                if generation == token { recognitionError = error.localizedDescription }
            }
        }
    }

    func finish() async {
        guard phase == .recording else { return }
        phase = .finishing
        meterTask?.cancel()
        stopCapture()
        await finalizeAnalysis()
    }

    private func finalizeAnalysis() async {
        let current = generation
        let analyzer = analyzer
        let results = results
        let sink = sink
        // Finalization must not leave a recording stuck indefinitely.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard generation == current else { return }
            recognitionError = "Transcription timed out. Your recording is preserved."
            await analyzer?.cancelAndFinishNow()
        }
        defer { timeout.cancel() }
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() }
        catch {
            guard generation == current else { return }
            recognitionError = recognitionError ?? error.localizedDescription
        }
        await results?.value
        guard generation == current else { return }
        self.analyzer = nil
        self.results = nil
        transcript = metadata.transcript
        if let failure = sink?.snapshot().error { recognitionError = failure }
        if recognitionError != nil || transcript == nil || !hasAudio {
            // Do not silently send a partial/failed transcription.
            transcript = nil
            error = recognitionError ?? "No speech recognised. Retry transcription or send audio only."
            phase = .failed
        } else {
            error = nil
            phase = .ready
        }
        do { try persist() } catch { self.error = error.localizedDescription; phase = .failed }
    }

    func retry() async {
        guard phase == .failed, hasAudio else { return }
        let token = generation
        phase = .finishing
        error = nil
        transcript = nil
        sink = nil
        do {
            let transcriber = try await prepareTranscriber(token: token)
            try check(token)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            listen(to: transcriber, token: generation)
            let file = try AVAudioFile(forReading: audioURL)
            try await analyzer.start(inputAudioFile: file, finishAfterFile: false)
            try check(token)
            await finalizeAnalysis()
        } catch {
            guard generation == token else { return }
            await stopEngineAndAnalysis()
            guard generation == token else { return }
            self.error = error.localizedDescription
            phase = .failed
        }
    }

    func leaveConversation() async {
        if phase == .recording { await finish() }
        if phase == .preparing { await discard() }
    }

    func discard() async {
        let token = UUID()
        generation = token
        preparationTask?.cancel()
        meterTask?.cancel()
        await stopEngineAndAnalysis()
        guard generation == token else { return }
        // Only this recorder's two owned draft files are removed.
        for file in [audioURL, directory.appendingPathComponent("draft.json")] {
            if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: file) }
        }
        sink = nil
        duration = 0
        levels = []
        liveLevels = []
        transcript = nil
        error = nil
        recoveringInput = false
        phase = .idle
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        sink?.finish()
        if let snapshot = sink?.snapshot() { duration = snapshot.duration; levels = snapshot.waveform }
    }

    private func stopEngineAndAnalysis() async {
        stopCapture()
        let analyzer = self.analyzer
        let results = self.results
        self.analyzer = nil
        self.results = nil
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func persist() throws {
        try JSONEncoder().encode(VoiceRecordingDraft(voice: metadata, transcriptionComplete: phase == .ready))
            .write(to: directory.appendingPathComponent("draft.json"), options: .atomic)
    }
}

struct VoiceFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The audio callback owns conversion and writing under one lock. Buffers sent
/// to SpeechAnalyzer are newly allocated and never modified after being yielded.
@available(macOS 26.0, *)
final class VoiceAudioSink: @unchecked Sendable {
    struct Snapshot {
        let duration: Double
        let waveform: [Float]
        let error: String?
        let silentDuration: Double
        let liveWaveform: [Float]
    }
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var frames: Int64 = 0
    private var peaks: [Float] = []
    private var failure: String?
    private var finished = false
    private var lastSignalFrame: Int64 = 0
    private var livePeaks: [Float] = []
    private var liveBucketFrames = 0
    private var liveBucketPeak: Float = 0

    init(url: URL, targetFormat: AVAudioFormat,
         continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        target = targetFormat
        self.continuation = continuation
        file = try AVAudioFile(forWriting: url, settings: targetFormat.settings,
                               commonFormat: targetFormat.commonFormat, interleaved: targetFormat.isInterleaved)
    }

    func consume(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        do {
            // Use the format actually delivered by the tap, including route
            // changes. A format captured before speech preparation can be stale.
            if converter?.inputFormat != input.format {
                converter = AVAudioConverter(from: input.format, to: target)
            }
            guard let converter else {
                throw VoiceFailure("The microphone audio format couldn’t be converted.")
            }
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            guard status != .error else { throw VoiceFailure("Microphone conversion failed.") }
            guard output.frameLength > 0 else { return }
            try file?.write(from: output)
            frames += Int64(output.frameLength)
            // Meter exactly the audio saved and sent to Speech, including integer
            // PCM formats. The source's first float channel is not always present.
            let peak = Self.peak(output)
            appendLiveSamples(output)
            if peak > 0.0001 { lastSignalFrame = frames }
            if peaks.count < 20_000 { peaks.append(min(1, peak)) }
            if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                failure = "Live transcription fell behind. The recording is preserved; retry transcription."
                continuation.finish()
            }
        } catch {
            failure = error.localizedDescription
            continuation.finish()
        }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        file = nil
        continuation.finish()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let width = max(1, Int(ceil(Double(peaks.count) / 100)))
        let waveform = stride(from: 0, to: peaks.count, by: width).map {
            peaks[$0..<min($0 + width, peaks.count)].max() ?? 0
        }
        return Snapshot(duration: Double(frames) / target.sampleRate, waveform: waveform, error: failure,
                        silentDuration: Double(frames - lastSignalFrame) / target.sampleRate,
                        liveWaveform: livePeaks)
    }

    // A stable 50ms time scale, independent of callback size and total duration.
    // Keep only the last 12 seconds for the live display; saved metadata retains
    // the separate full-recording overview above.
    private func appendLiveSamples(_ buffer: AVAudioPCMBuffer) {
        let bucketSize = max(1, Int(target.sampleRate * 0.05))
        var offset = 0
        while offset < Int(buffer.frameLength) {
            let end = min(Int(buffer.frameLength), offset + bucketSize - liveBucketFrames)
            liveBucketPeak = max(liveBucketPeak, Self.peak(buffer, frames: offset..<end))
            liveBucketFrames += end - offset
            offset = end
            if liveBucketFrames == bucketSize {
                livePeaks.append(liveBucketPeak)
                if livePeaks.count > 240 { livePeaks.removeFirst(livePeaks.count - 240) }
                liveBucketFrames = 0
                liveBucketPeak = 0
            }
        }
    }

    static func peak(_ buffer: AVAudioPCMBuffer, frames: Range<Int>? = nil) -> Float {
        var peak: Float = 0
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        for channel in 0..<channels {
            for frame in frames ?? 0..<Int(buffer.frameLength) {
                let index = interleaved ? frame * channels + channel : frame
                let plane = interleaved ? 0 : channel
                let sample: Float
                if let values = buffer.floatChannelData { sample = values[plane][index] }
                else if let values = buffer.int16ChannelData { sample = Float(values[plane][index]) / 32768 }
                else if let values = buffer.int32ChannelData { sample = Float(values[plane][index]) / 2147483648 }
                else { continue }
                if sample.isFinite { peak = max(peak, abs(sample)) }
            }
        }
        return min(1, peak)
    }
}
