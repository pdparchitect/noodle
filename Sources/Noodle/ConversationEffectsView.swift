import AppKit
import SwiftUI
import NoodleCore

/// View-local playback keeps effects out of transcript layout and scroll restoration.
struct ConversationEffectsView: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversationID: UUID
    @State private var playing: Playback?
    @State private var startedAt = Date.distantPast
    @State private var windowReference = EffectWindowReference()

    /// A preview has no queued event behind it, so playback keeps only what rendering needs.
    private struct Playback {
        let kind: ConversationEffectKind?
        let seed: UUID
    }

    /// A still acknowledgement, rather than moving particles or flashing.
    private func stillAcknowledgement(_ glyph: String) -> some View {
        Text(glyph)
            .font(.system(size: 40))
            .padding(12)
            .background(.regularMaterial, in: Circle())
    }

    private var isVisibleChat: Bool {
        guard let window = windowReference.window else { return false }
        return NSApp.isActive &&
            window.isVisible && !window.isMiniaturized && window.isKeyWindow && window.attachedSheet == nil
    }

    var body: some View {
        ZStack {
            if let playing, isVisibleChat {
                switch playing.kind {
                case .confetti:
                    if reduceMotion { stillAcknowledgement("🎉") }
                    else { ConfettiCanvas(seed: playing.seed, startedAt: startedAt) }
                case .fireworks:
                    if reduceMotion { stillAcknowledgement("🎆") }
                    else { FireworksCanvas(seed: playing.seed, startedAt: startedAt) }
                case nil:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(EffectWindowProbe(reference: windowReference))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .previewEffect)) { notification in
            guard NoodleAppIdentity.isDevelopment, isVisibleChat,
                  let kind = notification.object as? ConversationEffectKind else { return }
            startedAt = Date()
            playing = Playback(kind: kind, seed: UUID())
        }
        .task(id: conversationID) {
            playing = nil
            let repository = store.repository
            while !Task.isCancelled {
                if playing != nil, Date().timeIntervalSince(startedAt) >= 4 {
                    playing = nil
                }
                if isVisibleChat, playing == nil {
                    // Filesystem I/O and locking must not block the main thread.
                    let event = await Task.detached(priority: .utility) {
                        try? repository.takePendingEffect(conversationID: conversationID)
                    }.value
                    guard !Task.isCancelled else { return }
                    if let event, isVisibleChat, event.expiresAt > Date() {
                        startedAt = Date()
                        playing = Playback(kind: event.supportedKind, seed: event.id)
                    }
                } else if !isVisibleChat {
                    playing = nil
                }
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
        }
    }
}

@MainActor
private final class EffectWindowReference {
    weak var window: NSWindow?
}

private struct EffectWindowProbe: NSViewRepresentable {
    let reference: EffectWindowReference

    func makeNSView(context: Context) -> Probe {
        Probe(reference: reference)
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        let reference: EffectWindowReference
        init(reference: EffectWindowReference) {
            self.reference = reference
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { reference.window = window }
    }
}

private struct ConfettiCanvas: View {
    let seed: UUID
    let startedAt: Date
    private let colors: [Color] = [.pink, .orange, .yellow, .mint, .cyan, .purple]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                let seedValue = effectSeed(seed)
                for index in 0..<120 {
                    let phase = sample(seedValue, index, 1)
                    let time = elapsed - phase * 0.45
                    guard time >= 0, time < 3.8 else { continue }
                    let fromLeft = index.isMultiple(of: 2)
                    let direction = fromLeft ? 1.0 : -1.0
                    let velocityX = (0.18 + sample(seedValue, index, 2) * 0.45) * size.width
                    let velocityY = -(0.48 + sample(seedValue, index, 3) * 0.36) * size.height
                    let x = (fromLeft ? 0 : size.width) + direction * velocityX * time
                    let y = size.height * 0.72 + velocityY * time + size.height * 0.35 * time * time
                    var particle = context
                    particle.opacity = min(1, max(0, (3.8 - time) / 0.8))
                    particle.translateBy(x: x, y: y)
                    particle.rotate(by: .radians(time * (3 + phase * 8) * direction))
                    let width = 5 + sample(seedValue, index, 4) * 5
                    let flutter = 0.3 + abs(cos(time * 7 + phase * 6)) * 0.7
                    let rect = CGRect(x: -width / 2, y: -3, width: width, height: 6 * flutter)
                    particle.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(colors[index % colors.count]))
                }
            }
        }
    }
}

/// Rockets climb, burst into sparks that drag and fall, and leave short trails. Fits the 4 s playback window.
private struct FireworksCanvas: View {
    let seed: UUID
    let startedAt: Date
    private let rockets = 8, sparks = 64, rise = 0.7, life = 1.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                let seedValue = effectSeed(seed)
                var context = context
                // Overlapping sparks brighten towards white, as light does.
                context.blendMode = .plusLighter
                for rocket in 0..<rockets {
                    let time = elapsed - Double(rocket) * 1.8 / Double(rockets - 1)
                    guard time >= 0, time < rise + life else { continue }
                    let launchX = (0.15 + sample(seedValue, rocket, 1) * 0.7) * size.width
                    let apex = CGPoint(x: launchX + (sample(seedValue, rocket, 2) - 0.5) * 0.12 * size.width,
                                       y: (0.14 + sample(seedValue, rocket, 3) * 0.3) * size.height)
                    let hue = sample(seedValue, rocket, 4)
                    if time < rise {
                        // Ease out, so the rocket slows into its apex.
                        for step in 0..<10 {
                            let progress = max(0, time / rise - Double(step) * 0.012)
                            let eased = 1 - pow(1 - progress, 2.2)
                            let point = CGPoint(x: launchX + (apex.x - launchX) * eased,
                                                y: size.height + (apex.y - size.height) * eased)
                            let radius = 2.2 - Double(step) * 0.18
                            context.opacity = 1 - Double(step) / 10
                            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                                width: radius * 2, height: radius * 2)),
                                         with: .color(Color(hue: 0.11, saturation: 0.5, brightness: 1)))
                        }
                        continue
                    }
                    let burst = time - rise
                    if burst < 0.18 {
                        let radius = 30 + burst * 500
                        context.opacity = 1 - burst / 0.18
                        context.fill(Path(ellipseIn: CGRect(x: apex.x - radius, y: apex.y - radius,
                                                            width: radius * 2, height: radius * 2)),
                                     with: .radialGradient(Gradient(colors: [.white, .clear]), center: apex,
                                                           startRadius: 0, endRadius: radius))
                    }
                    let reach = min(size.width, size.height) * (0.2 + sample(seedValue, rocket, 5) * 0.14)
                    for spark in 0..<sparks {
                        let index = rocket * sparks + spark
                        let angle = sample(seedValue, index, 6) * 2 * .pi
                        let speed = 0.35 + sample(seedValue, index, 7) * 0.65
                        let lifetime = life * (0.7 + sample(seedValue, index, 8) * 0.3)
                        guard burst < lifetime else { continue }
                        let color = spark.isMultiple(of: 7) ? Color.white
                            : Color(hue: (hue + 1 + (sample(seedValue, index, 9) - 0.5) * 0.08).truncatingRemainder(dividingBy: 1),
                                    saturation: 0.85, brightness: 1)
                        let fade = 1 - pow(burst / lifetime, 3)
                        // A late flicker, like embers burning out.
                        let flicker = burst > lifetime * 0.6 ? 0.55 + 0.45 * sin(burst * 40 + Double(index)) : 1
                        func position(_ t: Double) -> CGPoint {
                            // Drag: distance approaches `reach` instead of growing without bound.
                            let distance = reach * speed * (1 - exp(-3.2 * max(0, t)))
                            return CGPoint(x: apex.x + cos(angle) * distance,
                                           y: apex.y + sin(angle) * distance + size.height * 0.07 * t * t)
                        }
                        // Tapering segments read as one streak; separate dots break apart at speed.
                        for step in 0..<5 {
                            let t = burst - Double(step) * 0.035
                            guard t >= 0 else { break }
                            var streak = Path()
                            streak.move(to: position(t))
                            streak.addLine(to: position(t - 0.035))
                            context.opacity = fade * flicker * (1 - Double(step) / 5)
                            context.stroke(streak, with: .color(color), style: StrokeStyle(
                                lineWidth: (3.4 - Double(step) * 0.55) * (0.6 + speed * 0.4), lineCap: .round))
                        }
                    }
                }
            }
        }
    }
}

private func effectSeed(_ seed: UUID) -> UInt64 {
    seed.uuidString.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
}

private func sample(_ seed: UInt64, _ index: Int, _ salt: UInt64) -> Double {
    var value = seed &+ UInt64(index) &* 0x9E3779B97F4A7C15 &+ salt &* 0xBF58476D1CE4E5B9
    value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
    value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
    return Double((value ^ (value >> 31)) & 0xFFFF) / 65535
}
