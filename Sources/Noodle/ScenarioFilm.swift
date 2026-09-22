#if NOODLE_DEV_HOOKS
import AppKit
import SwiftUI

// MARK: - Wordmark

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

// MARK: - Cards

/// What the film shows over the app, and the state its animations run from.
@MainActor @Observable final class ScenarioFilmModel {
    enum Card: Equatable {
        case intro(title: String, subtitle: String?)
        case outro(tagline: String?)
    }

    var card: Card?
    /// Set once the card is on screen, which starts every animation in it.
    var written = false
    /// Set to fade the card away and let the app back through.
    var leaving = false
    let onLight: Bool

    init(onLight: Bool) { self.onLight = onLight }

    /// The film opens on its title, so that card is solid the moment it is up; the
    /// closing one comes over the app and has to fade in.
    var covering: Bool {
        guard !leaving else { return false }
        switch card {
        case .intro: return true
        case .outro: return written
        case nil: return false
        }
    }

    var background: Color { onLight ? .white : .black }
    /// Plain ink on a plain card: white on black, black on white, with no tint of its own.
    var ink: Color { onLight ? .black : .white }
    var text: Color { ink }
}

/// The card the film lays over the app: a title to open with, the wordmark to close on.
struct ScenarioFilmView: View {
    @State var model: ScenarioFilmModel

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack {
                model.background
                switch model.card {
                case .intro(let title, let subtitle): intro(title, subtitle, height: height)
                case .outro(let tagline): outro(tagline, size: geometry.size)
                case nil: Color.clear
                }
            }
            .frame(width: geometry.size.width, height: height)
        }
        .opacity(model.covering ? 1 : 0)
        .animation(.easeInOut(duration: 0.75), value: model.covering)
        .ignoresSafeArea()
    }

    private func intro(_ title: String, _ subtitle: String?, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: height * 0.032) {
            Text(title)
                .font(.system(size: height * 0.082, weight: .semibold, design: .rounded))
                .foregroundStyle(model.text)
                .opacity(model.written ? 1 : 0)
                .offset(y: model.written ? 0 : height * 0.035)
                .animation(.easeOut(duration: 0.75).delay(0.25), value: model.written)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: height * 0.038, weight: .regular, design: .rounded))
                    .foregroundStyle(model.text.opacity(0.62))
                    .opacity(model.written ? 1 : 0)
                    .offset(y: model.written ? 0 : height * 0.025)
                    .animation(.easeOut(duration: 0.7).delay(0.6), value: model.written)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, height * 0.14)
    }

    private func outro(_ tagline: String?, size: CGSize) -> some View {
        VStack(spacing: size.height * 0.07) {
            let markSize = CGSize(width: size.width * 0.62, height: size.height * 0.2)
            NoodleWordmark(progress: model.written ? 1 : 0)
                .stroke(model.ink, style: StrokeStyle(
                    lineWidth: NoodleWordmark.lineWidth(in: CGRect(origin: .zero, size: markSize)),
                    lineCap: .round, lineJoin: .round))
                .frame(width: markSize.width, height: markSize.height)
                .animation(.easeInOut(duration: 2.1).delay(0.55), value: model.written)
            if let tagline {
                Text(tagline)
                    .font(.system(size: size.height * 0.036, weight: .regular, design: .rounded))
                    .foregroundStyle(model.text.opacity(0.62))
                    .opacity(model.written ? 1 : 0)
                    .animation(.easeOut(duration: 0.7).delay(2.5), value: model.written)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Stage

/// The windows a film needs: a solid backdrop behind the app, so the recording never
/// shows the desktop through its rounded corners, and a card over it for the titles.
@MainActor final class ScenarioFilmStage {
    let model: ScenarioFilmModel
    /// What a recording covers: the window with room around it, so the film shows an app
    /// on a desk rather than a screen filled edge to edge.
    private(set) var frame: NSRect = .zero
    private var backdrop: NSWindow?
    private var overlay: NSWindow?

    /// `opening` is set before the card is built, so the film's first frame is already
    /// solid rather than fading up from the app behind it.
    init(film: Scenario.Film, opening: ScenarioFilmModel.Card?) {
        model = ScenarioFilmModel(onLight: film.background == "white")
        model.card = opening
    }

    /// The margin around a window of this size, as a share of its shorter side.
    static let inset: CGFloat = 0.07

    /// Centres `window` on the screen inside a stage of its own, and puts the backdrop
    /// behind it and the card in front. Both cover the stage, which is what gets recorded.
    func attach(to window: NSWindow) {
        let visible = NSScreen.main?.visibleFrame ?? ScenarioSupport.screen
        let wanted = (min(window.frame.width, window.frame.height) * Self.inset).rounded()
        // A window close to the size of the screen gets whatever room is left.
        let margin = max(0, min(wanted, ((visible.width - window.frame.width) / 2).rounded(),
                                ((visible.height - window.frame.height) / 2).rounded()))
        let size = CGSize(width: window.frame.width + margin * 2, height: window.frame.height + margin * 2)
        frame = NSRect(x: (visible.midX - size.width / 2).rounded(),
                       y: (visible.midY - size.height / 2).rounded(),
                       width: size.width, height: size.height)
        window.setFrameOrigin(CGPoint(x: (frame.midX - window.frame.width / 2).rounded(),
                                      y: (frame.midY - window.frame.height / 2).rounded()))

        let backdrop = self.backdrop ?? makeWindow(opaque: true)
        backdrop.setFrame(frame, display: false)
        backdrop.backgroundColor = model.onLight ? .white : .black
        // Below the app's own window but, being one of its windows, still over every
        // other app's, so a recording shows the stage and never the desk behind it.
        backdrop.order(.below, relativeTo: window.windowNumber)
        self.backdrop = backdrop

        if overlay == nil {
            // A window comes with a content view of its own, so the card has to replace it.
            let made = makeWindow(opaque: false)
            made.contentView = NSHostingView(rootView: ScenarioFilmView(model: model))
            overlay = made
        }
        overlay?.setFrame(frame, display: false)
    }

    /// Brings the card up, ready to be written.
    func present(_ card: ScenarioFilmModel.Card) {
        model.card = card
        model.written = false
        model.leaving = false
        overlay?.setFrame(frame, display: false)
        overlay?.orderFront(nil)
    }

    /// Parks the pointer off the stage, so an unattended recording has no cursor in it.
    func hidePointer() {
        guard !frame.isEmpty else { return }
        let display = CGMainDisplayID()
        CGWarpMouseCursorPosition(CGPoint(x: CGFloat(CGDisplayPixelsWide(display)) - 1,
                                          y: CGFloat(CGDisplayPixelsHigh(display)) - 1))
    }

    /// Takes the card away and leaves the backdrop in place for the rest of the film.
    func dismissCard() {
        overlay?.orderOut(nil)
        model.card = nil
    }

    func finish() {
        overlay?.orderOut(nil)
        overlay?.contentView = nil
        overlay = nil
        backdrop?.orderOut(nil)
        backdrop = nil
    }

    private func makeWindow(opaque: Bool) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = opaque
        window.backgroundColor = opaque ? (model.onLight ? .white : .black) : .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Levels, not relative ordering: activating the app puts its own window in front,
        // which would leave the card behind the very thing it is meant to cover.
        window.level = opaque ? .normal : .floating
        return window
    }
}
#endif
