import AppKit
import SwiftUI
@_exported import NoodleWallpaperCore

/// One window-sized wallpaper. Load its replacement before fading so image-backed
/// conversations never flash the default canvas during a switch.
public struct ConversationWallpaper: View {
    let background: ConversationBackground
    var imageURL: URL?
    var imageData: Data?
    public init(background: ConversationBackground, imageURL: URL? = nil, imageData: Data? = nil) {
        self.background = background; self.imageURL = imageURL; self.imageData = imageData
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed = Layer(request: Request(background: ConversationBackground()))

    private struct Request: Equatable {
        let background: ConversationBackground
        var imageURL: URL?
        var imageData: Data?
    }

    private struct Layer: Identifiable {
        let id = UUID()
        let request: Request
        var image: NSImage?
    }

    public var body: some View {
        let request = Request(background: background, imageURL: imageURL, imageData: imageData)
        ZStack {
            Color(nsColor: .textBackgroundColor)
            ConversationBackgroundView(background: displayed.request.background,
                imageURL: displayed.request.imageURL, previewImage: displayed.image)
                .id(displayed.id)
                .transition(.opacity)
                .zIndex(1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: request) {
            guard request != displayed.request else { return }
            let image: NSImage?
            if let url = request.imageURL {
                let kind = request.background.mediaKind
                let poster = await Task.detached { await BackgroundMedia.poster(at: url, kind: kind) }.value
                image = poster.map { NSImage(cgImage: $0, size: .zero) }
            } else if let data = request.imageData {
                let decoded = await Task.detached { BackgroundMedia.image(data: data) }.value
                image = decoded.map { NSImage(cgImage: $0, size: .zero) }
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
                Color(nsColor: .textBackgroundColor)
                if let image = previewImage ?? loadedImage, background.imageFilename != nil {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if let preset = background.preset {
                    LinearGradient(colors: colors(preset), startPoint: .topLeading, endPoint: .bottomTrailing)
                    Ellipse().fill(colors(preset)[1].opacity(0.5))
                        .frame(width: geometry.size.width * 1.4, height: geometry.size.height * 1.1)
                        .rotationEffect(.degrees(-35)).offset(x: geometry.size.width * 0.35)
                        .blur(radius: 50)
                }
                if let imageURL, let kind = background.mediaKind, kind != .image {
                    AnimatedWallpaper(url: imageURL, kind: kind, reduceMotion: reduceMotion)
                }
                if !background.isDefault { Color.black.opacity(0.25) }
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

    private func colors(_ preset: ConversationBackgroundPreset) -> [Color] {
        switch preset {
        case .sunset: return [Color(red: 0.96, green: 0.52, blue: 0.15), Color(red: 0.77, green: 0.43, blue: 0.67), Color(red: 0.46, green: 0.35, blue: 0.75)]
        case .ocean: return [Color(red: 0.04, green: 0.26, blue: 0.50), Color(red: 0.08, green: 0.60, blue: 0.66), Color(red: 0.14, green: 0.30, blue: 0.62)]
        case .forest: return [Color(red: 0.08, green: 0.24, blue: 0.18), Color(red: 0.34, green: 0.53, blue: 0.30), Color(red: 0.14, green: 0.34, blue: 0.39)]
        case .dusk: return [Color(red: 0.18, green: 0.16, blue: 0.39), Color(red: 0.47, green: 0.29, blue: 0.60), Color(red: 0.73, green: 0.37, blue: 0.47)]
        }
    }
}
