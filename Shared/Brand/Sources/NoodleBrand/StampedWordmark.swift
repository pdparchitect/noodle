import SwiftUI

/// A name stamped one letter at a time: each letter drops onto the page, lands with a jolt that shakes the
/// whole word, and leaves a ring of its own shape behind. `stamped` runs once the last letter has settled.
public struct StampedWordmark: View {
    /// One letter, drawn in a box `capHeight` tall and `width` wide, in design units.
    public struct Letter: Sendable {
        public let shape: Path
        public let width: CGFloat

        public init(width: CGFloat, shape: Path) {
            self.width = width
            self.shape = shape
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How many letters have started their drop.
    @State private var dropped = 0
    /// How many letters have landed.
    @State private var landed = 0
    private let letters: [Letter]
    private let capHeight: CGFloat
    private let spacing: CGFloat
    private let height: CGFloat
    private let stamped: () -> Void

    /// `capHeight` and `spacing` are in the letters' design units; `height` is the drawn height in points.
    public init(letters: [Letter], capHeight: CGFloat, spacing: CGFloat, height: CGFloat,
                stamped: @escaping () -> Void = {}) {
        self.letters = letters
        self.capHeight = capHeight
        self.spacing = spacing
        self.height = height
        self.stamped = stamped
    }

    private static let drop = 0.12
    private static let settle = 0.13
    /// A tilt for each letter in the air, alternating so the word doesn't lean one way.
    private static let tilts: [Double] = [-8, 6, -5, 7, -6, 5]

    public var body: some View {
        let scale = height / capHeight
        HStack(spacing: spacing * scale) {
            ForEach(letters.indices, id: \.self) { index in
                let letter = letters[index]
                let shape = LetterShape(path: letter.shape, capHeight: capHeight)
                let down = index < dropped
                ZStack {
                    shape
                        .keyframeAnimator(initialValue: Ring(), trigger: landed > index) { ring, value in
                            ring.scaleEffect(value.scale).opacity(value.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.opacity) {
                                MoveKeyframe(0.45)
                                CubicKeyframe(0, duration: 0.5)
                            }
                            KeyframeTrack(\.scale) {
                                MoveKeyframe(1)
                                CubicKeyframe(1.45, duration: 0.5)
                            }
                        }
                    shape
                        .scaleEffect(down ? 1 : 2.1)
                        .rotationEffect(.degrees(down ? 0 : Self.tilts[index % Self.tilts.count]))
                        .opacity(down ? 1 : 0)
                        .blur(radius: down ? 0 : 6)
                }
                .frame(width: letter.width * scale, height: height)
            }
        }
        .keyframeAnimator(initialValue: CGSize.zero, trigger: landed) { word, offset in
            word.offset(offset)
        } keyframes: { _ in
            // A jolt in design units, scaled to the drawn height.
            KeyframeTrack(\.self) {
                LinearKeyframe(CGSize(width: -6 * scale, height: 4 * scale), duration: 0.04)
                LinearKeyframe(CGSize(width: 5 * scale, height: -3 * scale), duration: 0.04)
                LinearKeyframe(CGSize(width: -3.5 * scale, height: 2 * scale), duration: 0.04)
                LinearKeyframe(CGSize(width: 2 * scale, height: -1 * scale), duration: 0.04)
                LinearKeyframe(CGSize.zero, duration: 0.05)
            }
        }
        .accessibilityHidden(true)
        .task { await stamp() }
    }

    private func stamp() async {
        guard landed < letters.count else { return }
        if reduceMotion {
            dropped = letters.count
            landed = letters.count
            stamped()
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            for index in letters.indices {
                // Falls faster as it nears the page, then strikes.
                withAnimation(.timingCurve(0.55, 0, 1, 0.45, duration: Self.drop)) { dropped = index + 1 }
                try await Task.sleep(for: .seconds(Self.drop))
                landed = index + 1
                try await Task.sleep(for: .seconds(Self.settle))
            }
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }
        stamped()
    }

    private struct Ring {
        var opacity = 0.0
        var scale = 1.0
    }

    private struct LetterShape: Shape {
        let path: Path
        let capHeight: CGFloat

        func path(in rect: CGRect) -> Path {
            let scale = rect.height / capHeight
            return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
        }
    }
}

extension StampedWordmark.Letter {
    /// A closed polygon through `points`, in design units.
    public static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        Path { $0.addLines(points.map { CGPoint(x: $0.0, y: $0.1) }); $0.closeSubpath() }
    }

    /// A rectangle with its corners cut by `cut` at 45°.
    public static func octagon(_ rect: CGRect, cut: CGFloat) -> Path {
        polygon([(rect.minX + cut, rect.minY), (rect.maxX - cut, rect.minY), (rect.maxX, rect.minY + cut),
                 (rect.maxX, rect.maxY - cut), (rect.maxX - cut, rect.maxY), (rect.minX + cut, rect.maxY),
                 (rect.minX, rect.maxY - cut), (rect.minX, rect.minY + cut)])
    }

    /// A letter made of `parts` with `holes` cut out of it.
    public init(width: CGFloat, parts: [Path], holes: [Path] = []) {
        var shape = parts.dropFirst().reduce(parts.first ?? Path()) { $0.union($1) }
        for hole in holes { shape = shape.subtracting(hole) }
        self.init(width: width, shape: shape)
    }
}
