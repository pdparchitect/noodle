import AppKit
import SwiftUI
@_exported import NoodleWallpaperCore

/// One window-sized wallpaper. Load its replacement before fading so image-backed
/// conversations never flash the default canvas during a switch. Wallpapers are dark
/// scenes, so the window turns dark while one is shown, whatever the system says.
public struct ConversationWallpaper: View {
    let background: ConversationBackground
    var imageURL: URL?
    public init(background: ConversationBackground, imageURL: URL? = nil) {
        self.background = background; self.imageURL = imageURL
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed = Layer(request: Request(background: ConversationBackground()))

    private struct Request: Equatable {
        let background: ConversationBackground
        var imageURL: URL?
    }

    private struct Layer: Identifiable {
        let id = UUID()
        let request: Request
        var image: NSImage?
    }

    public var body: some View {
        let request = Request(background: background, imageURL: imageURL)
        ZStack {
            systemCanvas
            ConversationBackgroundView(background: displayed.request.background,
                imageURL: displayed.request.imageURL, previewImage: displayed.image)
                .id(displayed.id)
                .transition(.opacity)
                .zIndex(1)
        }
        .background(WallpaperWindowAppearance(isDark: !background.isDefault))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: request) {
            guard request != displayed.request else { return }
            let image: NSImage?
            if let url = request.imageURL {
                let kind = request.background.mediaKind
                let poster = await Task.detached { await BackgroundMedia.poster(at: url, kind: kind) }.value
                image = poster.map { NSImage(cgImage: $0, size: .zero) }
            } else {
                image = nil
            }
            guard !Task.isCancelled else { return }
            // Keep this transaction local to the wallpaper, not the transcript.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                displayed = Layer(request: request, image: image)
            }
        }
    }
}

public struct ConversationBackgroundView: View {
    let background: ConversationBackground
    var imageURL: URL?
    var previewImage: NSImage?
    public init(background: ConversationBackground, imageURL: URL? = nil, previewImage: NSImage? = nil) {
        self.background = background; self.imageURL = imageURL; self.previewImage = previewImage
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadedImage: NSImage?

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                systemCanvas
                if let image = previewImage ?? loadedImage, background.imageFilename != nil {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if let preset = background.preset {
                    PresetGradient(preset)
                }
                if let imageURL, background.mediaKind == .shader {
                    // Over its still, which shows until the first frame and stays on if it can't draw.
                    ShaderBackground(url: imageURL)
                } else if let imageURL, let kind = background.mediaKind, kind != .image {
                    AnimatedWallpaper(url: imageURL, kind: kind, reduceMotion: reduceMotion)
                }
                // Presets are drawn to sit behind bubbles; photos, videos and shaders are dimmed for them.
                if background.imageFilename != nil { Color.black.opacity(0.25) }
            }
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: imageURL) {
            loadedImage = nil
            guard let imageURL, previewImage == nil else { return }
            let kind = background.mediaKind
            let poster = await Task.detached { await BackgroundMedia.poster(at: imageURL, kind: kind) }.value
            guard !Task.isCancelled else { return }
            loadedImage = poster.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}

/// The default canvas in the system's appearance rather than the window's. A window that
/// turns dark for a wallpaper keeps this colour beneath the wallpaper fading in, not black.
@MainActor private var systemCanvas: Color {
    var color = NSColor.textBackgroundColor
    NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
        color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? color
    }
    return Color(nsColor: color)
}

/// Crossfades the whole window, chrome included, when its appearance changes. A window can hold
/// several wallpapers, one behind each column besides its own, so it is dark while any of them shows
/// a background. Its appearance is the wallpapers' to keep: when anything else resets it, as a change
/// of the system's appearance or a closing sheet may, it turns dark again.
private struct WallpaperWindowAppearance: NSViewRepresentable {
    let isDark: Bool

    final class Probe: NSView {
        private static let all = NSHashTable<Probe>.weakObjects()
        var isDark = false { didSet { Self.apply(to: window) } }
        private weak var shownIn: NSWindow?
        private var observation: NSKeyValueObservation?

        override init(frame: NSRect) { super.init(frame: frame); Self.all.add(self) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let previous = shownIn
            shownIn = window
            observation = window?.observe(\.appearance) { window, _ in
                // After whatever reset it has finished, not inside it.
                DispatchQueue.main.async { MainActor.assumeIsolated { Probe.apply(to: window) } }
            }
            if previous !== window { Self.apply(to: previous) }
            Self.apply(to: window)
        }

        static func wantsDark(_ window: NSWindow) -> Bool {
            all.allObjects.contains { $0.window === window && $0.isDark }
        }

        static func apply(to window: NSWindow?) {
            guard let window else { return }
            let appearance = wantsDark(window) ? NSAppearance(named: .darkAqua) : nil
            guard window.appearance?.name != appearance?.name else { return }
            if window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               let frame = window.contentView?.superview?.layer {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.35
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                frame.add(fade, forKey: fadeKey)
            }
            window.appearance = appearance
        }

        static let fadeKey = "noodle.wallpaper-appearance"
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.isDark = isDark }
}
