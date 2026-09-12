import AVFoundation
import SwiftUI
import Observation
import NoodleCore

/// The live meter has a fixed spatial/time scale, unlike the saved overview.
struct LiveVoiceWaveform: View {
    let samples: [Float]
    var duration: TimeInterval = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                  width: max(1, step - 2), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(Double(index) / Double(count) < progress ? .accentColor : .secondary.opacity(0.6)))
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor @Observable final class VoicePlayback {
    private static weak var active: VoicePlayback?
    private var player: AVAudioPlayer?
    private var timer: Task<Void, Never>?
    private(set) var playing = false
    private(set) var position: Double = 0
    private(set) var error: String?

    func toggle(url: URL) {
        if playing { stop(reset: false); return }
        do {
            if player == nil { player = try AVAudioPlayer(contentsOf: url) }
            Self.active?.stop(reset: false)
            Self.active = self
            guard let player else { return }
            if player.currentTime >= player.duration { player.currentTime = 0 }
            guard player.play() else { throw VoiceFailure("The recording couldn’t be played.") }
            playing = true
            error = nil
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
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

    func stop(reset: Bool = false) {
        timer?.cancel()
        timer = nil
        player?.pause()
        playing = false
        if reset { player?.currentTime = 0; position = 0 }
    }
}

struct VoiceMessagePlayer: View {
    let url: URL
    let voice: VoiceMessage
    var shouldPlay = true
    @State private var playback = VoicePlayback()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { playback.toggle(url: url) } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.playing ? "Pause voice message" : "Play voice message")
                GeometryReader { geometry in
                    VoiceWaveform(samples: voice.waveform, progress: playback.position / max(voice.duration, 1))
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            playback.seek(value.location.x / max(geometry.size.width, 1))
                        })
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
        .frame(width: 270)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onDisappear { playback.stop() }
        .onChange(of: shouldPlay) { _, visible in if !visible { playback.stop() } }
    }
}

func voiceTime(_ duration: Double) -> String {
    let seconds = duration.isFinite ? max(0, Int(duration)) : 0
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

struct VoiceTranscriptSheet: View {
    let voice: VoiceMessage
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.plain).foregroundStyle(.blue)
            }
            ScrollView { Text(voice.transcript ?? "No transcript available.").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 340)
        }
        .padding(20).frame(width: 440)
    }
}
