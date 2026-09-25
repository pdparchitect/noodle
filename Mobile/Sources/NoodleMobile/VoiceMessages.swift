import AVFoundation
import HubLink
import Observation
import Speech
import SwiftUI

/// Records a voice message and transcribes it on the device as it goes, as Noodle does on the Mac.
/// A recording that could not be transcribed is kept, to retry or send as audio alone.
@MainActor @Observable final class VoiceRecorder {
    enum Phase { case idle, preparing, recording, finishing, ready, failed }
    private(set) var phase: Phase = .idle
    private(set) var duration: TimeInterval = 0
    private(set) var levels: [Float] = []
    private(set) var liveLevels: [Float] = []
    private(set) var transcript: String?
    private(set) var error: String?
    private(set) var preparation = "Preparing speech…"
    var isSending = false
    let directory: URL
    var audioURL: URL { directory.appendingPathComponent("recording.caf") }
    var hasAudio: Bool { duration > 0 && FileManager.default.fileExists(atPath: audioURL.path) }
    var metadata: LinkVoice {
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LinkVoice(transcript: text?.isEmpty == false ? text : nil, duration: duration, waveform: levels,
                         localeIdentifier: localeIdentifier)
    }

    private var localeIdentifier: String?
    private var engine: AVAudioEngine?
    private var sink: VoiceAudioSink?
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var generation = UUID()
    private var recognitionError: String?

    init(directory: URL) { self.directory = directory }

    func start() {
        guard phase == .idle else { return }
        phase = .preparing
        error = nil
        let token = UUID()
        generation = token
        Task {
            do {
                let transcriber = try await prepareTranscriber(token: token)
                guard await AVAudioApplication.requestRecordPermission() else {
                    throw VoiceFailure("Microphone access is off. Turn it on for Noodle in Settings > Privacy & Security > Microphone.")
                }
                try check(token)
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    throw VoiceFailure("No supported microphone format is available.")
                }
                try check(token)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64))
                let sink = try VoiceAudioSink(url: audioURL, targetFormat: format, continuation: stream.continuation)
                self.sink = sink
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                self.analyzer = analyzer
                listen(to: transcriber, token: token)
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: stream.stream)
                try check(token)
                let engine = AVAudioEngine()
                let input = engine.inputNode
                input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
                    sink.consume(buffer)
                }
                try engine.start()
                self.engine = engine
                phase = .recording
                meter(token: token)
            } catch {
                guard generation == token else { return }
                await stopEngineAndAnalysis()
                self.error = error.localizedDescription
                phase = .failed
            }
        }
    }

    private func meter(token: UUID) {
        meterTask = Task {
            while !Task.isCancelled, generation == token, phase == .recording, let sink {
                try? await Task.sleep(for: .milliseconds(100))
                let snapshot = sink.snapshot()
                duration = snapshot.duration
                levels = snapshot.waveform
                liveLevels = snapshot.liveWaveform
                // The Mac's limit: eleven minutes at most, ten of recording.
                if snapshot.error != nil || duration >= 600 {
                    Task { await finish() }
                    break
                }
            }
        }
    }

    private func prepareTranscriber(token: UUID) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw VoiceFailure("On-device transcription isn’t available on this device or in its current language.")
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
        // Finishing must not leave a recording stuck.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard generation == current else { return }
            recognitionError = "Transcription timed out. Your recording is kept."
            await analyzer?.cancelAndFinishNow()
        }
        defer { timeout.cancel() }
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() } catch {
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
            // A partial or failed transcript is never sent without asking.
            transcript = nil
            error = recognitionError ?? "No speech recognised. Retry transcription or send audio only."
            phase = .failed
        } else {
            error = nil
            phase = .ready
        }
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
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            listen(to: transcriber, token: generation)
            try await analyzer.start(inputAudioFile: try AVAudioFile(forReading: audioURL), finishAfterFile: false)
            try check(token)
            await finalizeAnalysis()
        } catch {
            guard generation == token else { return }
            await stopEngineAndAnalysis()
            self.error = error.localizedDescription
            phase = .failed
        }
    }

    func discard() async {
        let token = UUID()
        generation = token
        meterTask?.cancel()
        await stopEngineAndAnalysis()
        guard generation == token else { return }
        try? FileManager.default.removeItem(at: audioURL)
        sink = nil
        duration = 0
        levels = []
        liveLevels = []
        transcript = nil
        error = nil
        phase = .idle
    }

    private func stopCapture() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
}

struct VoiceFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The audio callback owns conversion and writing under one lock. Buffers sent to the
/// transcriber are newly made and never changed after being handed over.
final class VoiceAudioSink: @unchecked Sendable {
    struct Snapshot {
        let duration: Double
        let waveform: [Float]
        let error: String?
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
    private var livePeaks: [Float] = []
    private var liveBucketFrames = 0
    private var liveBucketPeak: Float = 0

    init(url: URL, targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        target = targetFormat
        self.continuation = continuation
        file = try AVAudioFile(forWriting: url, settings: targetFormat.settings,
                               commonFormat: targetFormat.commonFormat, interleaved: targetFormat.isInterleaved)
    }

    func consume(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        do {
            // The format the microphone delivers can change with the route, as when headphones connect.
            if converter?.inputFormat != input.format { converter = AVAudioConverter(from: input.format, to: target) }
            guard let converter else { throw VoiceFailure("The microphone audio format couldn’t be converted.") }
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
            appendLiveSamples(output)
            if peaks.count < 20_000 { peaks.append(min(1, Self.peak(output))) }
            if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                failure = "Live transcription fell behind. The recording is kept; retry transcription."
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
        let waveform = stride(from: 0, to: peaks.count, by: width).map { peaks[$0..<min($0 + width, peaks.count)].max() ?? 0 }
        return Snapshot(duration: Double(frames) / target.sampleRate, waveform: waveform, error: failure, liveWaveform: livePeaks)
    }

    /// A steady 50 ms scale for the live meter, keeping the last 12 seconds.
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

/// Replaces the message field while recording, as on the Mac: discard, the live meter, the time, stop and send.
struct VoiceRecordingBar: View {
    let recorder: VoiceRecorder
    let send: (URL, LinkVoice) async throws -> Void
    @State private var sendError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { Task { await recorder.discard() } } label: {
                    Image(systemName: "xmark").frame(width: 30, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(recorder.isSending)
                .accessibilityLabel("Discard Recording")
                if recorder.phase == .preparing || recorder.phase == .finishing {
                    ProgressView()
                    Text(recorder.phase == .preparing ? recorder.preparation : "Finishing transcription…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    if recorder.phase == .recording {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        LiveVoiceWaveform(samples: recorder.liveLevels, duration: recorder.duration).frame(height: 22)
                    } else {
                        VoiceWaveform(samples: recorder.levels).frame(height: 22)
                    }
                    Text(voiceTime(recorder.duration)).font(.caption.monospacedDigit())
                    if recorder.phase == .recording {
                        Button { Task { await recorder.finish() } } label: {
                            Image(systemName: "stop.fill").frame(width: 30, height: 36)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop Recording")
                    }
                }
                Button { Task { await sendRecording() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(recorder.isSending || !(recorder.phase == .recording || recorder.phase == .ready))
                .accessibilityLabel("Send Voice Message")
            }
            if let error = sendError ?? recorder.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if recorder.phase == .failed && recorder.hasAudio {
                HStack {
                    Button("Retry Transcription") { Task { await recorder.retry() } }
                    Button("Send Audio Only") { Task { await sendRecording(audioOnly: true) } }
                }
                .font(.subheadline)
                .disabled(recorder.isSending)
            }
        }
    }

    private func sendRecording(audioOnly: Bool = false) async {
        guard !recorder.isSending else { return }
        recorder.isSending = true
        defer { recorder.isSending = false }
        sendError = nil
        if recorder.phase == .recording { await recorder.finish() }
        guard recorder.phase == .ready || (audioOnly && recorder.phase == .failed && recorder.hasAudio) else { return }
        do {
            try await send(recorder.audioURL, recorder.metadata)
            await recorder.discard()
        } catch {
            sendError = error.localizedDescription
        }
    }
}

/// The live meter keeps a fixed time scale, unlike the saved overview.
struct LiveVoiceWaveform: View {
    let samples: [Float]
    var duration: TimeInterval = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func bars(samples: [Float], width: CGFloat, height: CGFloat, sampleCount: Int, position: Double) -> [CGRect] {
        let spacing: CGFloat = 5
        let barWidth: CGFloat = 2.5
        return samples.enumerated().compactMap { offset, sample in
            let index = sampleCount - samples.count + offset
            let age = position - Double(index)
            let x = width - CGFloat(age) * spacing
            guard age > 0, x + barWidth > 0, x < width else { return nil }
            // A fixed decibel range shows quiet speech without making silence look loud.
            let amplitude = sample.isFinite ? max(0, min(1, sample)) : 0
            let decibels = 20 * log10(max(0.000001, amplitude))
            let normalized = CGFloat(max(0, min(1, (decibels + 60) / 48)))
            let barHeight = min(height, 2 + max(0, normalized * height - 2) * CGFloat(min(1, age)))
            return CGRect(x: x, y: (height - barHeight) / 2, width: barWidth, height: barHeight)
        }
    }

    var body: some View {
        let position = max(Double(samples.count), duration / 0.05)
        Bars(samples: samples, sampleCount: Int(position + 0.000001), position: position)
            .fill(.primary.opacity(0.7))
            .clipped()
            .animation(reduceMotion ? nil : .linear(duration: 0.1), value: position)
            .accessibilityLabel("Live microphone waveform")
    }

    private struct Bars: Shape {
        let samples: [Float]
        let sampleCount: Int
        var position: Double

        var animatableData: Double {
            get { position }
            set { position = newValue }
        }

        func path(in rect: CGRect) -> Path {
            Path { path in
                for bar in LiveVoiceWaveform.bars(samples: samples, width: rect.width, height: rect.height,
                                                  sampleCount: sampleCount, position: position) {
                    path.addRoundedRect(in: bar, cornerSize: CGSize(width: 1.25, height: 1.25))
                }
            }
        }
    }
}

struct VoiceWaveform: View {
    let samples: [Float]
    var progress: Double = 0

    var body: some View {
        Canvas { context, size in
            let count = max(1, min(60, samples.count))
            let step = size.width / CGFloat(count)
            for index in 0..<count {
                let value = samples.isEmpty ? 0 : samples[min(samples.count - 1, index * samples.count / count)]
                let height = max(2, CGFloat(sqrt(max(0, min(1, value)))) * size.height)
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: max(1, step - 2), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(Double(index) / Double(count) < progress ? .accentColor : .secondary.opacity(0.6)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Plays one recording at a time, as on the Mac.
@MainActor @Observable final class VoicePlayback {
    private static weak var active: VoicePlayback?
    private var player: AVAudioPlayer?
    private var loadedURL: URL?
    private var timer: Task<Void, Never>?
    private(set) var playing = false
    private(set) var position: Double = 0
    private(set) var error: String?

    func toggle(url: URL) {
        if loadedURL != url { reset() }
        if playing { stop(); return }
        do {
            // Through the speaker even with the ring switch set to silent, as a voice message expects.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            if player == nil { player = try AVAudioPlayer(contentsOf: url); loadedURL = url }
            Self.active?.stop()
            Self.active = self
            guard let player else { return }
            if player.currentTime >= player.duration { player.currentTime = 0 }
            guard player.play() else { throw VoiceFailure("The recording couldn’t be played.") }
            position = player.currentTime
            playing = true
            error = nil
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    position = player.currentTime
                    if !player.isPlaying { stop(rewind: true); break }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func seek(_ fraction: Double) {
        guard let player else { return }
        player.currentTime = min(player.duration, max(0, fraction * player.duration))
        position = player.currentTime
    }

    func stop(rewind: Bool = false) {
        timer?.cancel()
        timer = nil
        player?.pause()
        playing = false
        if rewind { player?.currentTime = 0; position = 0 }
    }

    func reset() {
        stop(rewind: true)
        player = nil
        loadedURL = nil
        error = nil
    }
}

/// A voice message in the conversation: play, the waveform to seek, and the time.
struct VoiceMessagePlayer: View {
    let url: URL?
    let voice: LinkVoice
    @State private var playback = VoicePlayback()
    @State private var showingTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { if let url { playback.toggle(url: url) } } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill").frame(width: 28, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(url == nil)
                .accessibilityLabel(playback.playing ? "Pause voice message" : "Play voice message")
                GeometryReader { geometry in
                    VoiceWaveform(samples: voice.waveform, progress: playback.position / max(voice.duration, 1))
                        .contentShape(Rectangle())
                        .onTapGesture { location in playback.seek(location.x / max(geometry.size.width, 1)) }
                }
                .frame(height: 28)
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue(voiceTime(playback.position))
                .accessibilityAdjustableAction { direction in
                    playback.seek((playback.position + (direction == .increment ? 5 : -5)) / max(voice.duration, 1))
                }
                Text(voiceTime(playback.playing ? playback.position : voice.duration))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(width: 250)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button("Show Transcript", systemImage: "text.quote") { showingTranscript = true }
        }
        .sheet(isPresented: $showingTranscript) {
            NavigationStack {
                ScrollView {
                    Text(voice.transcript ?? "No transcript available.").textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle("Transcript")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showingTranscript = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onDisappear { playback.stop() }
    }
}

func voiceTime(_ duration: Double) -> String {
    let seconds = duration.isFinite ? max(0, Int(duration)) : 0
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
