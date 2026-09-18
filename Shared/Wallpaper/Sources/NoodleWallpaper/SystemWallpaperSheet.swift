import AppKit
import AVFoundation
import ImageIO
import NoodleWallpaperCore
import SwiftUI

/// A grid of the system wallpapers already on this Mac. Presented by
/// `BackgroundPicker`, so every background editor shows the same dialog.
struct SystemWallpaperSheet: View {
    let reload: () -> [SystemWallpaper]
    let onChoose: (SystemWallpaper) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var wallpapers: [SystemWallpaper]

    /// System Settings downloads a wallpaper when it is picked there.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!

    init(wallpapers: [SystemWallpaper], reload: @escaping () -> [SystemWallpaper] = { SystemWallpaper.available() },
         onChoose: @escaping (SystemWallpaper) -> Void) {
        _wallpapers = State(initialValue: wallpapers)
        self.reload = reload
        self.onChoose = onChoose
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.blue)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("System Wallpapers").font(.headline).foregroundStyle(.primary)
                Spacer()
                Button("Wallpaper Settings…") { NSWorkspace.shared.open(Self.settingsURL) }.foregroundStyle(.blue)
            }.buttonStyle(.plain).padding(16)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(wallpapers, id: \.url) { wallpaper in
                        cell(wallpaper)
                    }
                }.padding(20)
            }
        }
        // Coming back from System Settings: show what was downloaded there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            wallpapers = reload()
        }
        // Wider than the 520-point editors that present it, so the previews are large enough to judge.
        .frame(width: 720, height: 560).controlSize(.regular)
        .presentationSizing(.fitted)
    }

    private func choose(_ wallpaper: SystemWallpaper) {
        onChoose(wallpaper)
        dismiss()
    }

    private func cell(_ wallpaper: SystemWallpaper) -> some View {
        VStack(spacing: 6) {
            SystemWallpaperThumbnail(wallpaper: wallpaper)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(wallpaper.name).font(.caption).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { choose(wallpaper) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wallpaper.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(wallpaper) }
    }
}

/// Apple ships a small thumbnail beside each wallpaper; decoding the multi-megabyte
/// original is only the fallback. Decoded off the main thread, once per launch.
private struct SystemWallpaperThumbnail: View {
    let wallpaper: SystemWallpaper
    @State private var image: NSImage?

    var body: some View {
        Color.secondary.opacity(0.14)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
            }
            .task(id: wallpaper.url) { image = await Self.load(wallpaper) }
    }

    @MainActor private static var cache: [URL: NSImage] = [:]

    @MainActor private static func load(_ wallpaper: SystemWallpaper) async -> NSImage? {
        if let cached = cache[wallpaper.url] { return cached }
        let source = wallpaper.thumbnailURL ?? wallpaper.url
        let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            // A video without a shipped thumbnail shows its first frame.
            guard let source = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                let generator = AVAssetImageGenerator(asset: BackgroundMedia.videoAsset(at: source))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 360, height: 360)
                return try? await generator.image(at: .zero).image
            }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 360
            ] as CFDictionary)
        }.value
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        cache[wallpaper.url] = image
        return image
    }
}
