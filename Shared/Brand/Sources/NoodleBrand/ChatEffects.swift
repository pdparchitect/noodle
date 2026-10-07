import SwiftUI

/// A moment a bot marks in a conversation, drawn the same on every device. Effects travel between apps by
/// name; one an app does not know is no effect there.
public enum ChatEffect: String, CaseIterable, Sendable {
    case confetti
    case fireworks

    /// How long one plays.
    public static let duration: TimeInterval = 4

    /// Shown still, instead of moving particles or flashing, when motion is reduced.
    var glyph: String {
        switch self {
        case .confetti: "🎉"
        case .fireworks: "🎆"
        }
    }
}

/// One effect playing from `startedAt`, over whatever it is laid on. It takes no touches.
public struct ChatEffectView: View {
    let effect: ChatEffect
    let seed: UUID
    let startedAt: Date
    /// A moment to draw still, rather than playing, and whether motion is reduced then.
    var frozenAt: TimeInterval?
    var reducesMotion: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(effect: ChatEffect, seed: UUID, startedAt: Date) {
        self.effect = effect
        self.seed = seed
        self.startedAt = startedAt
    }

    init(effect: ChatEffect, seed: UUID, frozenAt: TimeInterval, reducesMotion: Bool) {
        self.init(effect: effect, seed: seed, startedAt: Date())
        self.frozenAt = frozenAt
        self.reducesMotion = reducesMotion
    }

    public var body: some View {
        Group {
            if reducesMotion ?? reduceMotion {
                Text(effect.glyph)
                    .font(.system(size: 40))
                    .padding(12)
                    .background(.regularMaterial, in: Circle())
            } else {
                switch effect {
                case .confetti: ConfettiCanvas(seed: seed, startedAt: startedAt, frozenAt: frozenAt)
                case .fireworks: FireworksCanvas(seed: seed, startedAt: startedAt, frozenAt: frozenAt)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ConfettiCanvas: View {
    let seed: UUID
    let startedAt: Date
    let frozenAt: TimeInterval?
    private let colors: [Color] = [.pink, .orange, .yellow, .mint, .cyan, .purple]

    var body: some View {
        EffectClock(startedAt: startedAt, frozenAt: frozenAt) { elapsed in
            Canvas { context, size in
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
    let frozenAt: TimeInterval?
    private let rockets = 8, sparks = 64, rise = 0.7, life = 1.4

    var body: some View {
        EffectClock(startedAt: startedAt, frozenAt: frozenAt) { elapsed in
            Canvas { context, size in
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

/// How long an effect has played: by the display's clock, or at a fixed moment for a still frame.
private struct EffectClock<Content: View>: View {
    let startedAt: Date
    let frozenAt: TimeInterval?
    @ViewBuilder let content: (TimeInterval) -> Content

    var body: some View {
        if let frozenAt {
            content(frozenAt)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in content(timeline.date.timeIntervalSince(startedAt)) }
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
