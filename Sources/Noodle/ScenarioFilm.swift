#if NOODLE_DEV_HOOKS
import AVFoundation
import AppKit
import SwiftUI

// MARK: - Film

/// Titles around a scenario, so a recording opens and closes the same way every time. The apps that play
/// scenarios share it, with their own closing mark.
struct ScenarioFilm: Codable {
    /// What is behind the app and under the titles: "black", "white", or a picture
    /// or video, named as an asset in the scenario folder or as a web address.
    var background: String?
    var intro: Intro?
    var outro: Outro?

    struct Intro: Codable {
        /// A picture to bring up under the title, shown in a circle. Any asset in the
        /// scenario folder, so it can be a bot's own avatar or anything else.
        var icon: String?
        /// "white" or "black", for a mark that is drawn in the wrong one.
        var iconTint: String?
        /// The small line above the title, for what this is a scenario of.
        var kicker: String?
        /// Defaults to the scenario's own title.
        var title: String?
        var subtitle: String?
        /// Seconds to stay on the finished card. Default 1.4.
        var hold: Double?
    }

    struct Outro: Codable {
        var tagline: String?
        /// Seconds to stay on the finished mark. Default 1.6.
        var hold: Double?
    }

    enum Stage { case intro, outro }

    static let tints: Set<String> = ["white", "black", "none"]

    /// What a recording can move in on.
    static let focusRegions: Set<String> = ["composer", "transcript", "none"]

    var isLight: Bool { background == "white" }
    /// The picture or video behind everything, if the background is not just a colour.
    var media: String? {
        let value = background ?? "black"
        return ["black", "white"].contains(value) ? nil : value
    }

    /// `media` finds a picture or video the film names, and throws when it is missing.
    func validate(media: (String) throws -> URL) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ScenarioError(message) }
        }
        if let backdrop = self.media { _ = try media(backdrop) }
        for (label, text) in [("intro.kicker", intro?.kicker), ("intro.title", intro?.title),
                              ("intro.subtitle", intro?.subtitle), ("outro.tagline", outro?.tagline)] {
            try require(text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true, "film.\(label) has no text.")
        }
        try require((intro?.hold ?? 0) >= 0 && (outro?.hold ?? 0) >= 0, "A film holds for a negative time.")
        if let icon = intro?.icon { _ = try media(icon) }
        try require(Self.tints.contains(intro?.iconTint ?? "none"), "film.intro.iconTint is white or black.")
    }

    /// The picture the opening card brings up, if it names one.
    @MainActor func icon(media: (String) throws -> URL) -> NSImage? {
        guard let path = intro?.icon, let url = try? media(path), var image = NSImage(contentsOf: url) else { return nil }
        if let tint = intro?.iconTint { image = ScenarioSupport.tinted(image, tint) }
        return ScenarioSupport.roomAround(image)
    }
}

// MARK: - Cards

/// What the film shows over the app, and the state its animations run from.
@MainActor @Observable final class ScenarioFilmModel {
    enum Card: Equatable {
        case intro(kicker: String?, title: String, subtitle: String?, icon: NSImage?)
        case outro(tagline: String?)
    }

    var card: Card?
    /// Set once the card is on screen, which starts every animation in it.
    var written = false
    /// Set to take the words off a card that stays up, so the film goes to nothing
    /// before the app appears rather than dissolving into it.
    var emptying = false
    /// Set to fade the card away and let the app back through.
    var leaving = false
    let onLight: Bool
    /// Whether a picture or video is playing behind everything, titles included.
    let hasMedia: Bool
    /// The app's mark on the closing card, drawn in `ink` as the card is written; without one, the app's icon comes up.
    @ObservationIgnored let mark: Mark?

    typealias Mark = @MainActor (_ written: Bool, _ ink: Color, _ size: CGSize) -> AnyView

    init(onLight: Bool, hasMedia: Bool = false, mark: Mark? = nil) {
        self.onLight = onLight
        self.hasMedia = hasMedia
        self.mark = mark
    }

    /// How solid a card is. Over a moving background it thins to a veil, so the
    /// background runs through the whole film instead of being covered up for the titles.
    var scrim: Double { hasMedia ? 0.62 : 1 }

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

    /// Whether the words on the card are up.
    var lettering: Bool { written && !emptying }

    var background: Color { (onLight ? Color.white : Color.black).opacity(scrim) }
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
                case .intro(let kicker, let title, let subtitle, let icon):
                    intro(kicker, title, subtitle, icon, height: height)
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

    /// The spacing that leaves `multiple` of the size between baselines. A stack lays
    /// text out frame by frame, so a line height tighter than the font's own has to come
    /// out of the spacing between them.
    static func leading(size: CGFloat, weight: NSFont.Weight, multiple: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return multiple * size - (font.ascender - font.descender + font.leading)
    }

    /// Set the way Apple sets a page like this: a small line above, the title tight and
    /// slightly closed up, and a quieter line under it.
    private func intro(_ kicker: String?, _ title: String, _ subtitle: String?, _ icon: NSImage?, height: CGFloat) -> some View {
        ZStack {
            words(kicker, title, subtitle, height: height)
            if let icon {
                VStack {
                    Spacer()
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: height * 0.13, height: height * 0.13)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(model.ink.opacity(0.16), lineWidth: max(1, height * 0.002)))
                        .scaleEffect(model.written ? 1 : 0.7)
                        .opacity(model.written ? 1 : 0)
                        .animation(.spring(response: 0.6, dampingFraction: 0.62).delay(0.95), value: model.written)
                        .padding(.bottom, height * 0.22)
                }
            }
        }
        .opacity(model.lettering ? 1 : 0)
        .animation(.easeInOut(duration: 0.45), value: model.lettering)
    }

    private func words(_ kicker: String?, _ title: String, _ subtitle: String?, height: CGFloat) -> some View {
        let headline = height * 0.078
        let above = headline * 0.44, below = headline * 0.36
        return VStack(spacing: 0) {
            if let kicker {
                Text(kicker)
                    .font(.system(size: above, weight: .semibold))
                    .tracking(above * 0.011)
                    .foregroundStyle(model.text)
                    .padding(.bottom, headline * 0.3)
                    .modifier(RisesIn(written: model.written, by: height * 0.02, delay: 0.2))
            }
            VStack(spacing: Self.leading(size: headline, weight: .semibold, multiple: 1.0835)) {
                ForEach(Array(title.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                }
            }
            .font(.system(size: headline, weight: .semibold))
            .tracking(headline * -0.003)
            .foregroundStyle(model.text)
            .modifier(RisesIn(written: model.written, by: height * 0.03, delay: 0.35))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: below, weight: .regular))
                    .tracking(below * -0.022)
                    .foregroundStyle(model.text.opacity(0.58))
                    .padding(.top, headline * 0.45)
                    .modifier(RisesIn(written: model.written, by: height * 0.02, delay: 0.62))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, height * 0.1)
    }

    private func outro(_ tagline: String?, size: CGSize) -> some View {
        VStack(spacing: size.height * 0.07) {
            let markSize = CGSize(width: size.width * 0.62, height: size.height * 0.2)
            if let mark = model.mark {
                mark(model.written, model.ink, markSize)
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: markSize.height * 1.2, height: markSize.height * 1.2)
                    .scaleEffect(model.written ? 1 : 0.7)
                    .opacity(model.written ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.62).delay(0.55), value: model.written)
            }
            if let tagline {
                let size = size.height * 0.036
                Text(tagline)
                    .font(.system(size: size, weight: .regular))
                    .tracking(size * -0.022)
                    .foregroundStyle(model.text.opacity(0.58))
                    .opacity(model.written ? 1 : 0)
                    .animation(.easeOut(duration: 0.7).delay(2.5), value: model.written)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Fades a line up into place once the card is written.
private struct RisesIn: ViewModifier {
    let written: Bool
    let by: CGFloat
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(written ? 1 : 0)
            .offset(y: written ? 0 : by)
            .animation(.easeOut(duration: 0.75).delay(delay), value: written)
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
    private weak var staged: NSWindow?

    /// `opening` is set before the card is built, so the film's first frame is already
    /// solid rather than fading up from the app behind it.
    /// A picture or video to lay behind the app instead of a plain colour.
    private let backdropMedia: URL?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?

    private let film: ScenarioFilm
    private let title: String
    private let opening: ScenarioFilmModel.Card?

    /// `media` finds the pictures and videos the film names; `title` is the scenario's, for an intro without its own.
    init(film: ScenarioFilm, title: String, media: (String) throws -> URL, mark: ScenarioFilmModel.Mark? = nil) {
        let backdrop = film.media.flatMap { try? media($0) }
        self.film = film
        self.title = title
        opening = film.intro.map { .intro(kicker: $0.kicker, title: $0.title ?? title, subtitle: $0.subtitle, icon: film.icon(media: media)) }
        model = ScenarioFilmModel(onLight: film.isLight, hasMedia: backdrop != nil, mark: mark)
        model.card = opening
        backdropMedia = backdrop
    }

    /// Stages `window` for a recording, with the opening card covering it from the first frame.
    func open(on window: NSWindow) {
        attach(to: window)
        if let opening {
            present(opening)
            // The card owns the screen from the first frame, so the app never shows
            // through a background that the titles only veil.
            conceal()
        }
        hidePointer()
    }

    /// The titles. Their timings are fixed so every film opens and closes alike; a
    /// scenario chooses only the words and how long the finished card stays up.
    func play(_ stage: ScenarioFilm.Stage, sleep: @MainActor (Duration) async throws -> Void) async throws {
        let card: ScenarioFilmModel.Card?, written: Double
        switch stage {
        case .intro:
            card = opening
            written = 1.6 + (film.intro?.hold ?? 1.4)
        case .outro:
            card = film.outro.map { .outro(tagline: $0.tagline) }
            written = 3.3 + (film.outro?.hold ?? 1.6)
        }
        guard let card else {
            if stage == .outro { finish() }
            return
        }
        // The opening card is already up, from before the recorder started; presenting it
        // again only makes sure it is in front of the window it covers.
        present(card)
        // A frame with the card in its starting state, so its animations have something to run from.
        try await sleep(.milliseconds(60))
        model.written = true
        var remaining = written
        if stage == .outro, model.hasMedia {
            // Let the veil settle over the app, then take the app away and leave the
            // background playing behind the mark.
            try await sleep(.seconds(0.85))
            conceal()
            remaining -= 0.85
        }
        try await sleep(.seconds(max(0, remaining)))
        // A recording ends on the closing mark.
        guard stage == .intro else { return }
        // The words go, the card holds on nothing, and only then does the app come up.
        // Never a dissolve of one into the other.
        model.emptying = true
        try await sleep(.seconds(0.6))
        if model.hasMedia {
            // The veil lifts and the background plays alone before the app arrives.
            model.leaving = true
            try await sleep(.seconds(0.7))
        }
        conceal()
        dismissCard()
        try await sleep(.seconds(0.35))
        reveal(over: 0.55)
        try await sleep(.seconds(0.6))
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

        staged = window
        let backdrop = self.backdrop ?? makeWindow(opaque: true)
        backdrop.setFrame(frame, display: false)
        backdrop.backgroundColor = model.onLight ? .white : .black
        layBackdropMedia(in: backdrop)
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
        model.emptying = false
        model.leaving = false
        overlay?.setFrame(frame, display: false)
        overlay?.orderFront(nil)
    }

    /// Puts the picture or video behind the app, filling the stage and losing whatever
    /// falls outside it. A video loops and is silent: the film's own track is added later.
    private func layBackdropMedia(in window: NSWindow) {
        guard let backdropMedia else { return }
        let host = window.contentView ?? NSView(frame: frame)
        host.wantsLayer = true
        window.contentView = host
        if let playerLayer {
            playerLayer.frame = host.bounds
            return
        }
        if ["mp4", "m4v", "mov"].contains(backdropMedia.pathExtension.lowercased()) {
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: backdropMedia))
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = host.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            host.layer?.addSublayer(layer)
            player.play()
            self.player = player
            playerLayer = layer
        } else if let image = NSImage(contentsOf: backdropMedia) {
            host.layer?.contents = image
            host.layer?.contentsGravity = .resizeAspectFill
        }
    }

    /// Takes the app out of sight, so an emptied card can come down to nothing.
    func conceal() { staged?.alphaValue = 0 }

    /// Brings the app up out of the backdrop.
    func reveal(over seconds: Double) {
        guard let window = staged, window.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = seconds
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
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
        player?.pause()
        player = nil
        looper = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
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
// MARK: - Cues

/// The lines a capture run tells scripts/scenario.sh, which records the screen and makes the film's moves afterwards.
@MainActor enum ScenarioCue {
    /// What `screencapture -R` should take: the film's stage if there is one, otherwise the
    /// window. As x, y from the top left, width, height.
    static func region(stage: ScenarioFilmStage?, window: NSWindow?) -> String? {
        guard let frame = stage.map(\.frame) ?? window?.frame, !frame.isEmpty else { return nil }
        return "\(Int(frame.minX)),\(Int(ScenarioSupport.screen.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
    }

    /// Something just made a noise, and when.
    static func sound(_ name: String) -> String { "SCENARIO SOUND \(name) \(Date().timeIntervalSince1970)" }

    /// What the recording should move in on, as a box inside the recorded area with its
    /// origin at the top left: "composer", "transcript", or "none" for the whole area.
    static func focus(_ region: String, in window: NSWindow, stage: ScenarioFilmStage?, over move: Double, steady: Bool) -> String? {
        let area = stage.map(\.frame) ?? window.frame
        guard !area.isEmpty else { return nil }
        var box = area
        if region != "none" {
            guard let wanted = wantedBox(region, in: window) else { return nil }
            // Kept inside the window: the margin around it belongs to the stage, and
            // moving in on that would show black.
            box = ScenarioSupport.fit(wanted, shapedLike: area, inside: window.frame)
        }
        let line = [box.minX - area.minX, area.maxY - box.maxY, box.width, box.height]
            .map { String(Int($0.rounded())) }.joined(separator: ",")
        return "SCENARIO FOCUS \(line) \(move) \(steady ? "steady" : "eased") \(Date().timeIntervalSince1970)"
    }

    /// The conversation column, taken from the split view rather than by hunting for a
    /// view: the sidebar holds a scroller of its own and is easily mistaken for it.
    private static func wantedBox(_ region: String, in window: NSWindow) -> NSRect? {
        let item = ScenarioSupport.splitController(in: window.contentView)?.splitViewItems.first
        let sidebar = item?.isCollapsed == true ? 0 : (item?.viewController.view.frame.width ?? 0)
        let column = NSRect(x: window.frame.minX + sidebar, y: window.frame.minY,
                            width: window.frame.width - sidebar, height: window.frame.height)
        switch region {
        case "composer":
            // The composer and the last of the conversation above it, held around
            // whatever is being written so the picture follows the words.
            let band = NSRect(x: column.minX, y: column.minY, width: column.width, height: column.height * 0.52)
            let width = column.width * 0.78
            guard let text = ScenarioSupport.firstView(in: window.contentView, matching: { $0 is ComposerTextView }) as? NSTextView else {
                return band
            }
            let caret = text.firstRect(forCharacterRange: NSRange(location: text.string.utf16.count, length: 0), actualRange: nil)
            guard caret.midX > 0 else { return band }
            return NSRect(x: caret.midX - width / 2, y: band.minY, width: width, height: band.height)
        case "transcript": return column
        default: return nil
        }
    }
}
#endif
