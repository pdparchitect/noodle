import AppKit
import AVFoundation
import SwiftUI
import Observation
import NoodleCore

/// The live meter has a fixed spatial/time scale, unlike the saved overview.
struct LiveVoiceWaveform: View {
    let samples: [Float]
    var duration: TimeInterval = 0
    var started = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Audio arrives in uneven chunks, so the playhead follows the clock a quarter
    /// second behind and never passes the audio received so far.
    static func position(elapsed: TimeInterval, sampleCount: Int) -> Double {
        min(Double(sampleCount), max(0, (elapsed - 0.25) / 0.05))
    }

    static func bars(samples: [Float], width: CGFloat, height: CGFloat,
                     sampleCount: Int? = nil, position: Double? = nil) -> [CGRect] {
        let spacing: CGFloat = 5
        let barWidth: CGFloat = 2.5
        let count = sampleCount ?? samples.count
        let position = position ?? Double(count)
        // Audio-time indices stay stable when the bounded sample history rolls
        // over. Only the playhead moves; existing bars keep their amplitudes.
        return samples.enumerated().compactMap { offset, sample in
            let index = count - samples.count + offset
            let age = position - Double(index)
            let x = width - CGFloat(age) * spacing
            guard age > 0, x + barWidth > 0, x < width else { return nil }
            // A fixed dB range makes normal quiet speech visible without
            // auto-normalizing silence or changing the recording's audio gain.
            let amplitude = sample.isFinite ? max(0, min(1, sample)) : 0
            let decibels = 20 * log10(max(0.000001, amplitude))
            let normalized = CGFloat(max(0, min(1, (decibels + 60) / 48)))
            let reveal = CGFloat(min(1, age))
            let barHeight = min(height, 2 + max(0, normalized * height - 2) * reveal)
            return CGRect(x: x,
                          y: (height - barHeight) / 2, width: barWidth, height: barHeight)
        }
    }

    var body: some View {
        let sampleCount = max(samples.count, Int(duration / 0.05 + 0.000001))
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : nil)) { timeline in
            Bars(samples: samples, sampleCount: sampleCount,
                 position: Self.position(elapsed: timeline.date.timeIntervalSince(started), sampleCount: sampleCount))
                .fill(.primary.opacity(0.7))
                .clipped()
        }
        .accessibilityLabel("Live microphone waveform")
    }

    private struct Bars: Shape {
        let samples: [Float]
        let sampleCount: Int
        let position: Double

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
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                  width: max(1, step - 2), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(Double(index) / Double(count) < progress ? .accentColor : .secondary.opacity(0.6)))
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor protocol VoicePlaybackPlayer: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    func play() -> Bool
    func pause()
}

extension AVAudioPlayer: VoicePlaybackPlayer {}

@MainActor @Observable final class VoicePlayback {
    private static weak var active: VoicePlayback?
    private var player: (any VoicePlaybackPlayer)?
    private var loadedURL: URL?
    private var timer: Task<Void, Never>?
    private let makePlayer: (URL) throws -> any VoicePlaybackPlayer
    private let sleep: (Duration) async throws -> Void
    private(set) var playing = false
    private(set) var position: Double = 0
    private(set) var error: String?

    init(makePlayer: @escaping (URL) throws -> any VoicePlaybackPlayer = { try AVAudioPlayer(contentsOf: $0) },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.makePlayer = makePlayer; self.sleep = sleep
    }

    func toggle(url: URL) {
        if loadedURL != url { resetRecording() }
        if playing { stop(reset: false); return }
        do {
            if player == nil { player = try makePlayer(url); loadedURL = url }
            Self.active?.stop(reset: false)
            Self.active = self
            guard let player else { return }
            if player.currentTime >= player.duration { player.currentTime = 0 }
            guard player.play() else { throw VoiceFailure("The recording couldn’t be played.") }
            position = player.currentTime
            playing = true
            error = nil
            let sleep = sleep
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await sleep(.milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    position = player.currentTime
                    if !player.isPlaying { stop(reset: true); break }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func seek(_ fraction: Double) {
        guard let player else { return }
        player.currentTime = min(player.duration, max(0, fraction * player.duration))
        position = player.currentTime
    }

    /// Seeks a recording that may not have played yet, loading it without playing it.
    func seek(_ fraction: Double, in url: URL) {
        if loadedURL != url { resetRecording() }
        if player == nil {
            do { player = try makePlayer(url); loadedURL = url; error = nil } catch {
                self.error = error.localizedDescription
                return
            }
        }
        seek(fraction)
    }

    func stop(reset: Bool = false) {
        timer?.cancel()
        timer = nil
        player?.pause()
        playing = false
        if reset { player?.currentTime = 0; position = 0 }
    }

    func resetRecording() {
        stop(reset: true)
        player = nil; loadedURL = nil; error = nil
    }
}

extension Binding where Value == Bool {
    /// Whether the voice message `id` shows its transcript, where a message shows one at a time and its menu can open it.
    @MainActor static func showsTranscript(of id: UUID, in shown: Binding<UUID?>) -> Binding<Bool> {
        Binding(get: { shown.wrappedValue == id }, set: { show in
            if show { shown.wrappedValue = id } else if shown.wrappedValue == id { shown.wrappedValue = nil }
        })
    }
}

struct VoiceMessagePlayer: View {
    let url: URL
    let voice: VoiceMessage
    var shouldPlay = true
    @State private var playback: VoicePlayback
    @State private var showsTranscriptHere = false
    /// Lets the message's menu open the same transcript.
    private let showsTranscript: Binding<Bool>?

    @MainActor init(url: URL, voice: VoiceMessage, shouldPlay: Bool = true, playback: VoicePlayback? = nil,
                    showsTranscript: Binding<Bool>? = nil) {
        self.url = url; self.voice = voice; self.shouldPlay = shouldPlay; self.showsTranscript = showsTranscript
        _playback = State(initialValue: playback ?? VoicePlayback())
    }

    private var transcriptShown: Binding<Bool> { showsTranscript ?? $showsTranscriptHere }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VoicePlayButton(playback: playback, url: url)
                VoiceWaveform(samples: voice.waveform, progress: playback.position / max(voice.duration, 1))
                    .frame(height: 28)
                    .accessibilityElement()
                    .accessibilityLabel("Playback position")
                    .accessibilityValue(voiceTime(playback.position))
                    .accessibilityAdjustableAction { direction in
                        playback.seek((playback.position + (direction == .increment ? 5 : -5)) / max(voice.duration, 1), in: url)
                    }
                    .accessibilityAction(named: "Show Transcript") { transcriptShown.wrappedValue = true }
                Text(voiceTime(playback.playing ? playback.position : voice.duration))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(idealWidth: 270, maxWidth: 270)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        // Only a click opens the transcript, so dragging the message still exports the recording.
        .onTapGesture { transcriptShown.wrappedValue = true }
        .help("Show Transcript")
        .popover(isPresented: transcriptShown, arrowEdge: .bottom) {
            VoiceTranscriptView(url: url, voice: voice, playback: playback)
        }
        .onDisappear { playback.stop() }
        .onChange(of: url) { _, _ in playback.resetRecording() }
        .onChange(of: shouldPlay) { _, visible in if !visible { playback.stop() } }
    }
}

struct VoicePlayButton: View {
    let playback: VoicePlayback
    let url: URL

    var body: some View {
        Button { playback.toggle(url: url) } label: {
            Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                .frame(width: 28, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.playing ? "Pause voice message" : "Play voice message")
        .help(playback.playing ? "Pause" : "Play")
    }
}

func voiceTime(_ duration: Double) -> String {
    let seconds = duration.isFinite ? max(0, Int(duration)) : 0
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// A voice message's transcript matched to its recording. Transcripts have no word timings,
/// so the match is by proportion: a fraction of the recording is the same fraction of the
/// transcript's characters, and the sentence holding that character is the one being said.
struct VoiceTranscriptText: Equatable {
    static let missing = "No transcript was made for this voice message."
    let text: String
    /// Each sentence without the spaces after it, in order.
    let sentences: [Range<String.Index>]
    /// Where each sentence starts, in characters.
    let starts: [Int]
    let count: Int

    /// Nil when nothing was transcribed.
    init?(_ transcript: String?) {
        guard let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        var sentences: [Range<String.Index>] = [], starts: [Int] = []
        var offset = 0, counted = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            offset += text.distance(from: counted, to: range.lowerBound)
            counted = range.lowerBound
            var end = range.upperBound
            while end > range.lowerBound, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
            guard end > range.lowerBound else { return }
            sentences.append(range.lowerBound..<end)
            starts.append(offset)
        }
        if sentences.isEmpty { sentences = [text.startIndex..<text.endIndex]; starts = [0] }
        self.text = text; self.sentences = sentences; self.starts = starts; count = text.count
    }

    /// The sentence being said at a fraction of the recording.
    func sentence(at fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        let offset = Int((min(1, max(0, fraction)) * Double(count)).rounded())
        return starts.lastIndex { $0 <= offset } ?? 0
    }

    /// How far into the recording a sentence starts.
    func fraction(of sentence: Int) -> Double {
        guard starts.indices.contains(sentence), count > 0 else { return 0 }
        return Double(starts[sentence]) / Double(count)
    }
}

/// Splits a transcript once rather than on every tick of playback.
@MainActor final class VoiceTranscriptSplit {
    private var source: String??
    private var value: VoiceTranscriptText?

    func callAsFunction(_ transcript: String?) -> VoiceTranscriptText? {
        if source != .some(transcript) { source = .some(transcript); value = VoiceTranscriptText(transcript) }
        return value
    }
}

/// The transcript as selectable text. Each sentence is a link that plays from it, and the one
/// being played is marked.
struct VoiceTranscriptBody: View {
    static let scheme = "noodle-transcript-sentence"
    let transcript: VoiceTranscriptText
    let highlighted: Int?

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            // Sentences read as plain text, not as links.
            .tint(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var result = AttributedString(transcript.text)
        for (index, sentence) in transcript.sentences.enumerated() {
            guard let range = Range(sentence, in: result) else { continue }
            result[range].link = URL(string: "\(Self.scheme):\(index)")
            if index == highlighted { result[range].swiftUI.backgroundColor = Color.accentColor.opacity(0.28) }
        }
        return result
    }

    static func sentence(in url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.absoluteString.dropFirst(scheme.count + 1))
    }
}

/// A waveform that clicking or dragging moves through the recording.
struct VoiceSeekingWaveform: View {
    let samples: [Float]
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            VoiceWaveform(samples: samples, progress: progress)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    seek(drag.location.x / max(geometry.size.width, 1))
                })
        }
    }
}

/// A voice message's balloon: its recording to play and move through, and its transcript, with
/// the sentence being played marked. It shares the message's playback, so both show the same.
struct VoiceTranscriptView: View {
    let url: URL
    let voice: VoiceMessage
    let playback: VoicePlayback
    @State private var split = VoiceTranscriptSplit()
    @State private var scroll = ScrollPosition()
    @State private var textHeight: CGFloat = 0
    @State private var visible = CGRect.zero

    private static let maxTextHeight: CGFloat = 260

    var body: some View {
        let transcript = split(voice.transcript)
        let fraction = playback.position / max(voice.duration, 1)
        // A recording that has not been played or moved through has no place in the text yet.
        let highlighted = transcript.flatMap { playback.playing || playback.position > 0 ? $0.sentence(at: fraction) : nil }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VoicePlayButton(playback: playback, url: url)
                VoiceSeekingWaveform(samples: voice.waveform, progress: fraction) { playback.seek($0, in: url) }
                    .frame(height: 28)
                    .accessibilityElement()
                    .accessibilityLabel("Playback position")
                    .accessibilityValue(voiceTime(playback.position))
                    .accessibilityAdjustableAction { direction in
                        playback.seek((playback.position + (direction == .increment ? 5 : -5)) / max(voice.duration, 1), in: url)
                    }
                Text("\(voiceTime(playback.position)) / \(voiceTime(voice.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            if let transcript {
                ScrollView {
                    VoiceTranscriptBody(transcript: transcript, highlighted: highlighted)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                }
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in visible = rect }
                .frame(height: min(max(textHeight, 1), Self.maxTextHeight))
                .environment(\.openURL, OpenURLAction { link in
                    guard let index = VoiceTranscriptBody.sentence(in: link) else { return .systemAction }
                    playback.seek(transcript.fraction(of: index), in: url)
                    return .handled
                })
                .onChange(of: highlighted) { _, index in reveal(index, in: transcript) }
                HStack {
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript.text, forType: .string)
                    }
                }
            } else {
                Text(VoiceTranscriptText.missing).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    /// Scrolls the marked sentence into view, at about where it falls in the text.
    private func reveal(_ index: Int?, in transcript: VoiceTranscriptText) {
        guard let index, textHeight > visible.height, visible.height > 0 else { return }
        let y = transcript.fraction(of: index) * textHeight
        guard y < visible.minY + 8 || y > visible.maxY - 24 else { return }
        withAnimation { scroll.scrollTo(y: min(textHeight - visible.height, max(0, y - visible.height / 3))) }
    }
}
