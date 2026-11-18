#if NOODLE_DEV_HOOKS
import AppKit
import SwiftUI

/// The Noodle wordmark drawn as one pen stroke: the app's own `n`, then `oodle` in the
/// same weight and on the same baseline, so a film can write the name on screen.
///
/// The geometry is the icon's own 1254 grid. The `n` is the centre line of the shape in
/// `Support/AppSymbol.svg`, which is a single round-capped stroke; `ScenarioFilmTests`
/// renders both and fails if they drift apart.
struct NoodleWordmark: Shape {
    /// How much of the stroke has been written, from nothing to the whole word.
    var progress: Double = 1

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// The pen, and the lines it is written between, in design units.
    static let pen: CGFloat = 128
    static let baseline: CGFloat = 906
    static let xHeightTop: CGFloat = 343
    static let ascenderTop: CGFloat = 183
    /// The box the stroked word occupies, pen included.
    static let bounds = CGRect(x: 0, y: 119, width: 3819, height: 851)

    private static let kappa: CGFloat = 0.5523
    private static let xHeight = baseline - xHeightTop
    private static let bowlRadius = xHeight / 2
    private static let bowlCentre = (baseline + xHeightTop) / 2
    private static let letterGap: CGFloat = 44
    /// What the `n` occupies, tail included.
    private static let nWidth: CGFloat = 707

    /// The whole word, in design units, in the order a hand would write it.
    static let skeleton: CGPath = {
        let path = CGMutablePath()
        var x: CGFloat = 0
        appendN(to: path, at: x)
        x += nWidth + letterGap
        for letter in "oodle" {
            switch letter {
            case "o":
                appendBowl(to: path, at: x)
                x += xHeight + pen + letterGap
            case "d":
                appendBowl(to: path, at: x)
                appendStem(to: path, x: x + pen / 2 + bowlRadius * 2)
                x += xHeight + pen + letterGap
            case "l":
                appendStem(to: path, x: x + pen / 2)
                x += pen + letterGap
            case "e":
                appendE(to: path, at: x)
                x += xHeight + pen + letterGap
            default: break
            }
        }
        return path
    }()

    /// Up the left stem, over the arch, down the right stem and out along the tail.
    private static func appendN(to path: CGMutablePath, at x: CGFloat) {
        let left = x + pen / 2, right = left + 452, middle = (left + right) / 2
        let springY: CGFloat = 569, radius: CGFloat = 226, pull = radius * kappa
        path.move(to: CGPoint(x: left, y: baseline))
        path.addLine(to: CGPoint(x: left, y: springY))
        path.addCurve(to: CGPoint(x: middle, y: springY - radius),
                      control1: CGPoint(x: left, y: springY - pull),
                      control2: CGPoint(x: middle - pull, y: springY - radius))
        path.addCurve(to: CGPoint(x: right, y: springY),
                      control1: CGPoint(x: middle + pull, y: springY - radius),
                      control2: CGPoint(x: right, y: springY - pull))
        path.addLine(to: CGPoint(x: right, y: 818))
        path.addCurve(to: CGPoint(x: right + 127, y: 899),
                      control1: CGPoint(x: right, y: 913),
                      control2: CGPoint(x: right + 67, y: 910))
    }

    /// A circle, written anticlockwise from the top, for `o` and the bowl of `d`.
    private static func appendBowl(to path: CGMutablePath, at x: CGFloat) {
        let centreX = x + pen / 2 + bowlRadius, centreY = bowlCentre
        let radius = bowlRadius, pull = radius * kappa
        path.move(to: CGPoint(x: centreX, y: centreY - radius))
        path.addCurve(to: CGPoint(x: centreX - radius, y: centreY),
                      control1: CGPoint(x: centreX - pull, y: centreY - radius),
                      control2: CGPoint(x: centreX - radius, y: centreY - pull))
        path.addCurve(to: CGPoint(x: centreX, y: centreY + radius),
                      control1: CGPoint(x: centreX - radius, y: centreY + pull),
                      control2: CGPoint(x: centreX - pull, y: centreY + radius))
        path.addCurve(to: CGPoint(x: centreX + radius, y: centreY),
                      control1: CGPoint(x: centreX + pull, y: centreY + radius),
                      control2: CGPoint(x: centreX + radius, y: centreY + pull))
        path.addCurve(to: CGPoint(x: centreX, y: centreY - radius),
                      control1: CGPoint(x: centreX + radius, y: centreY - pull),
                      control2: CGPoint(x: centreX + pull, y: centreY - radius))
    }

    private static func appendStem(to path: CGMutablePath, x: CGFloat) {
        path.move(to: CGPoint(x: x, y: ascenderTop))
        path.addLine(to: CGPoint(x: x, y: baseline))
    }

    /// The bar left to right, then up over the top, round the left and along the
    /// bottom, ending open at the lower right.
    private static func appendE(to path: CGMutablePath, at x: CGFloat) {
        let centreX = x + pen / 2 + bowlRadius, centreY = bowlCentre
        let radius = bowlRadius, pull = radius * kappa
        path.move(to: CGPoint(x: centreX - radius, y: centreY))
        path.addLine(to: CGPoint(x: centreX + radius, y: centreY))
        path.addCurve(to: CGPoint(x: centreX, y: centreY - radius),
                      control1: CGPoint(x: centreX + radius, y: centreY - pull),
                      control2: CGPoint(x: centreX + pull, y: centreY - radius))
        path.addCurve(to: CGPoint(x: centreX - radius, y: centreY),
                      control1: CGPoint(x: centreX - pull, y: centreY - radius),
                      control2: CGPoint(x: centreX - radius, y: centreY - pull))
        path.addCurve(to: CGPoint(x: centreX, y: centreY + radius),
                      control1: CGPoint(x: centreX - radius, y: centreY + pull),
                      control2: CGPoint(x: centreX - pull, y: centreY + radius))
        path.addCurve(to: CGPoint(x: centreX + radius * 0.74, y: centreY + radius * 0.70),
                      control1: CGPoint(x: centreX + pull * 0.62, y: centreY + radius),
                      control2: CGPoint(x: centreX + radius * 0.50, y: centreY + radius * 0.90))
    }

    /// The word scaled into `rect`, written as far as `progress`.
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.bounds.width, rect.height / Self.bounds.height)
        guard scale > 0 else { return Path() }
        let width = Self.bounds.width * scale, height = Self.bounds.height * scale
        var transform = CGAffineTransform(translationX: rect.midX - width / 2, y: rect.midY - height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -Self.bounds.minX, y: -Self.bounds.minY)
        guard let scaled = Self.skeleton.copy(using: &transform) else { return Path() }
        let full = Path(scaled)
        return progress >= 1 ? full : full.trimmedPath(from: 0, to: max(0, progress))
    }

    /// The pen width for a word drawn into `rect`.
    static func lineWidth(in rect: CGRect) -> CGFloat {
        pen * min(rect.width / bounds.width, rect.height / bounds.height)
    }
}

extension NoodleWordmark {
    /// The wordmark as a film's closing card writes it, in one stroke.
    static let filmMark: ScenarioFilmModel.Mark = { written, ink, size in
        AnyView(NoodleWordmark(progress: written ? 1 : 0)
            .stroke(ink, style: StrokeStyle(lineWidth: lineWidth(in: CGRect(origin: .zero, size: size)), lineCap: .round, lineJoin: .round))
            .frame(width: size.width, height: size.height)
            .animation(.easeInOut(duration: 2.1).delay(0.55), value: written))
    }
}
#endif
