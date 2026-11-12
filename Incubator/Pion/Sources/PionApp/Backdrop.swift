import SwiftUI

/// What moves behind the frosted window, chosen in View › Background Effect. Every effect is
/// monochrome and quiet enough to read over, and holds still when the person asks for less motion.
enum BackdropEffect: String, CaseIterable, Identifiable {
    case none, glyphs, grid, scanlines, network

    static let key = "PionBackdropEffect"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .glyphs: "Falling Glyphs"
        case .grid: "Grid"
        case .scanlines: "Scanlines"
        case .network: "Network"
        }
    }
}

/// The window's backdrop.
struct Backdrop: View {
    @AppStorage(BackdropEffect.key) private var effect = BackdropEffect.glyphs.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let kind = BackdropEffect(rawValue: effect) ?? .glyphs
        if kind != .none {
            // A dozen frames a second is plenty for something this slow, and spares the battery.
            TimelineView(.periodic(from: .now, by: reduceMotion ? 3600 : 1.0 / 12)) { context in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let ink = colorScheme == .dark ? Color.white : Color.black
                Canvas(rendersAsynchronously: true) { canvas, size in
                    switch kind {
                    case .none: break
                    case .glyphs: Self.glyphs(canvas, size, time, ink)
                    case .grid: Self.grid(canvas, size, time, ink)
                    case .scanlines: Self.scanlines(canvas, size, time, ink)
                    case .network: Self.network(canvas, size, time, ink)
                    }
                }
            }
            // Softened a little, as if seen through the frosted window rather than printed on it.
            .blur(radius: 0.7)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// A stable pseudo-random number for an index, so each column or point keeps its own character.
    private static func seed(_ index: Int) -> UInt64 { UInt64(truncatingIfNeeded: index &* 2_654_435_761) & 0xFFFF_FFFF }

    // MARK: Falling glyphs

    private static let hex = Array("0123456789ABCDEF")

    /// Columns of hex falling at their own pace, each with a brighter head and a fading trail.
    private static func glyphs(_ canvas: GraphicsContext, _ size: CGSize, _ time: Double, _ ink: Color) {
        let cell = CGSize(width: 14, height: 18)
        let columns = Int(size.width / cell.width) + 1, rows = Int(size.height / cell.height) + 1
        for column in 0..<columns {
            let seed = seed(column)
            let speed = 2.0 + Double(seed % 5), trail = 6 + Int(seed % 14)
            let span = rows + trail + 8 + Int(seed % 23)
            let head = Int(time * speed + Double(seed % 997)) % span
            for offset in 0..<trail {
                let row = head - offset
                guard row >= 0, row < rows else { continue }
                let fade = 1 - Double(offset) / Double(trail)
                let pick = Int((UInt64(row) &* 31 &+ seed &+ UInt64(time * 2)) % UInt64(hex.count))
                let text = Text(String(hex[pick]))
                    .font(.system(size: 11, weight: offset == 0 ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(ink.opacity((offset == 0 ? 0.24 : 0.1) * fade))
                canvas.draw(text, at: CGPoint(x: CGFloat(column) * cell.width + cell.width / 2, y: CGFloat(row) * cell.height + cell.height / 2))
            }
        }
    }

    // MARK: Grid

    /// A faint dot grid that a slow horizontal scan brightens as it passes.
    private static func grid(_ canvas: GraphicsContext, _ size: CGSize, _ time: Double, _ ink: Color) {
        let step: CGFloat = 22
        let scan = CGFloat((time * 40).truncatingRemainder(dividingBy: Double(size.height + 240))) - 120
        var y: CGFloat = step / 2
        while y < size.height {
            let near = max(0, 1 - abs(y - scan) / 120)
            var x: CGFloat = step / 2
            while x < size.width {
                let radius: CGFloat = 0.9 + near * 0.6
                canvas.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                            with: .color(ink.opacity(0.09 + near * 0.18)))
                x += step
            }
            y += step
        }
    }

    // MARK: Scanlines

    /// Fine lines as on a terminal's glass, with a soft band of light drifting down them.
    private static func scanlines(_ canvas: GraphicsContext, _ size: CGSize, _ time: Double, _ ink: Color) {
        let band = CGFloat((time * 28).truncatingRemainder(dividingBy: Double(size.height + 400))) - 200
        var y: CGFloat = 0
        while y < size.height {
            let near = max(0, 1 - abs(y - band) / 200)
            canvas.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(ink.opacity(0.035 + near * 0.07)))
            y += 3
        }
    }

    // MARK: Network

    /// Points drifting slowly, joined by faint lines while they are close: a topology seen from far off.
    private static func network(_ canvas: GraphicsContext, _ size: CGSize, _ time: Double, _ ink: Color) {
        let count = max(24, Int(size.width * size.height / 26_000))
        let points: [CGPoint] = (0..<count).map { index in
            let seed = seed(index + 7)
            let speed = 0.02 + Double(seed % 7) / 300
            let phase = Double(seed % 628) / 100
            let x = (Double(seed % 1000) / 1000 + 0.06 * sin(time * speed + phase)) * Double(size.width)
            let y = (Double((seed / 1000) % 1000) / 1000 + 0.06 * cos(time * speed * 1.3 + phase)) * Double(size.height)
            return CGPoint(x: x, y: y)
        }
        let reach: CGFloat = 150
        for i in points.indices {
            for j in points.indices where j > i {
                let distance = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                guard distance < reach else { continue }
                var line = Path()
                line.move(to: points[i])
                line.addLine(to: points[j])
                canvas.stroke(line, with: .color(ink.opacity(0.12 * (1 - distance / reach))), lineWidth: 0.6)
            }
            canvas.fill(Path(ellipseIn: CGRect(x: points[i].x - 1.6, y: points[i].y - 1.6, width: 3.2, height: 3.2)),
                        with: .color(ink.opacity(0.22)))
        }
    }
}
