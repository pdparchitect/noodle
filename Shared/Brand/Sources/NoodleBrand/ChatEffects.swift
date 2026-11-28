// Drawn with SwiftUI, so only where SwiftUI is; the faces and names build everywhere.
#if canImport(SwiftUI)
import SwiftUI

/// A moment a bot marks in a conversation, drawn the same on every device. Effects travel between apps by
/// name; one an app does not know is no effect there.
public enum ChatEffect: String, CaseIterable, Sendable {
    case confetti
    case fireworks
    case pasta

    /// How long one plays.
    public static let duration: TimeInterval = 4

    /// Shown still, instead of moving particles or flashing, when motion is reduced.
    var glyph: String {
        switch self {
        case .confetti: "🎉"
        case .fireworks: "🎆"
        case .pasta: "🍝"
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
                case .pasta: PastaCanvas(seed: seed, startedAt: startedAt, frozenAt: frozenAt)
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

/// Pasta tumbles down from above, swaying as it falls, for a moment nobody is quite sure about.
/// Fits the 4 s playback window.
private struct PastaCanvas: View {
    let seed: UUID
    let startedAt: Date
    let frozenAt: TimeInterval?
    private let pieces = 72, fall = 2.6
    // Durum wheat in its shades, with the odd tomato and spinach piece.
    private let colors: [Color] = [
        Color(red: 0.98, green: 0.84, blue: 0.47), Color(red: 0.95, green: 0.74, blue: 0.33),
        Color(red: 0.99, green: 0.9, blue: 0.62), Color(red: 0.89, green: 0.62, blue: 0.27),
        Color(red: 0.98, green: 0.84, blue: 0.47), Color(red: 0.95, green: 0.74, blue: 0.33),
        Color(red: 0.86, green: 0.38, blue: 0.24), Color(red: 0.52, green: 0.66, blue: 0.29)
    ]

    var body: some View {
        EffectClock(startedAt: startedAt, frozenAt: frozenAt) { elapsed in
            Canvas { context, size in
                let seedValue = effectSeed(seed)
                let scale = max(0.8, min(1.4, min(size.width, size.height) / 400))
                for index in 0..<pieces {
                    let time = elapsed - sample(seedValue, index, 1) * 1.3
                    let duration = fall * (0.8 + sample(seedValue, index, 2) * 0.4)
                    guard time >= 0, time < duration else { continue }
                    let progress = time / duration
                    let sway = sin(time * (1.5 + sample(seedValue, index, 3) * 2) + Double(index)) * 18 * scale
                    // From just above the top edge to just below the bottom, gathering speed.
                    let y = -30 * scale + (size.height + 60 * scale) * (progress * 0.55 + progress * progress * 0.45)
                    var piece = context
                    piece.opacity = min(1, (duration - time) / 0.4)
                    piece.translateBy(x: sample(seedValue, index, 4) * size.width + sway, y: y)
                    piece.rotate(by: .radians(sample(seedValue, index, 5) * 2 * .pi
                        + time * (sample(seedValue, index, 6) - 0.5) * 6))
                    piece.scaleBy(x: scale, y: scale)
                    let color = colors[Int(sample(seedValue, index, 7) * Double(colors.count)) % colors.count]
                    Self.draw(PastaShape.allCases[index % PastaShape.allCases.count], in: piece, color: color)
                }
            }
        }
    }

    private enum PastaShape: CaseIterable { case penne, farfalle, fusilli, macaroni }

    /// One piece about 24 points long, centred on the origin. Ridges and openings are a shade darker.
    private static func draw(_ shape: PastaShape, in context: GraphicsContext, color: Color) {
        let shade = GraphicsContext.Shading.color(Color(red: 0.45, green: 0.27, blue: 0.08).opacity(0.4))
        switch shape {
        case .penne:
            var tube = Path()
            tube.move(to: CGPoint(x: -12, y: -4))
            tube.addLine(to: CGPoint(x: 8, y: -4))
            tube.addLine(to: CGPoint(x: 12, y: 4))
            tube.addLine(to: CGPoint(x: -8, y: 4))
            tube.closeSubpath()
            context.fill(tube, with: .color(color))
            var ridges = Path()
            for offset in [-1.5, 1.5] {
                ridges.move(to: CGPoint(x: -9 + offset, y: offset))
                ridges.addLine(to: CGPoint(x: 9 + offset, y: offset))
            }
            context.stroke(ridges, with: shade, lineWidth: 0.8)
            var opening = Path()
            opening.move(to: CGPoint(x: 8, y: -4))
            opening.addLine(to: CGPoint(x: 12, y: 4))
            context.stroke(opening, with: shade, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        case .farfalle:
            var wings = Path()
            for side in [-1.0, 1.0] {
                wings.move(to: .zero)
                wings.addLine(to: CGPoint(x: side * 11, y: -8))
                wings.addQuadCurve(to: CGPoint(x: side * 11, y: 0), control: CGPoint(x: side * 13.5, y: -4))
                wings.addQuadCurve(to: CGPoint(x: side * 11, y: 8), control: CGPoint(x: side * 8.5, y: 4))
                wings.closeSubpath()
            }
            context.fill(wings, with: .color(color))
            var ridges = Path()
            for side in [-1.0, 1.0] {
                for y in [-4.0, 0, 4] {
                    ridges.move(to: CGPoint(x: side * 3, y: y * 0.3))
                    ridges.addLine(to: CGPoint(x: side * 9.5, y: y))
                }
            }
            context.stroke(ridges, with: shade, lineWidth: 0.7)
            let knot = Path(roundedRect: CGRect(x: -2.5, y: -3.5, width: 5, height: 7), cornerRadius: 2)
            context.fill(knot, with: .color(color))
            context.fill(knot, with: shade)
        case .fusilli:
            func twist(_ phase: Double) -> Path {
                var path = Path()
                for step in 0...24 {
                    let x = -11 + Double(step) * 22 / 24
                    let point = CGPoint(x: x, y: sin(x * 0.85 + phase) * 2.6)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }
            context.stroke(twist(0), with: .color(color), style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
            context.stroke(twist(.pi / 2), with: shade, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        case .macaroni:
            var elbow = Path()
            elbow.addArc(center: CGPoint(x: 0, y: 6), radius: 9, startAngle: .degrees(200), endAngle: .degrees(340),
                         clockwise: false)
            context.stroke(elbow, with: .color(color), style: StrokeStyle(lineWidth: 6.5, lineCap: .butt))
            let end = CGPoint(x: 9 * cos(340 * Double.pi / 180), y: 6 + 9 * sin(340 * Double.pi / 180))
            context.fill(Path(ellipseIn: CGRect(x: end.x - 1.6, y: end.y - 3.2, width: 3.2, height: 6.4)), with: shade)
        }
    }
}

/// How long an effect has played:by the display's clock, or at a fixed moment for a still frame.
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
#endif
