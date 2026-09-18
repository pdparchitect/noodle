import AppKit
import SwiftUI
import NoodleWallpaperCore

/// Use the same SwiftUI bezel as Create Image; only the opened menu is AppKit.
/// Native pop-up buttons have different intrinsic sizing and bezel metrics.
public struct ImageSourceMenu: View {
    let title: String
    let chooseFile: () -> Void
    let choosePhoto: () -> Void
    /// Backgrounds pass this to offer the system wallpapers already on disk.
    var chooseWallpaper: ((URL) -> Void)? = nil
    @State private var presenter = Presenter()

    public init(title: String, chooseFile: @escaping () -> Void, choosePhoto: @escaping () -> Void,
                chooseWallpaper: ((URL) -> Void)? = nil) {
        self.title = title
        self.chooseFile = chooseFile
        self.choosePhoto = choosePhoto
        self.chooseWallpaper = chooseWallpaper
    }

    public var body: some View {
        Button {
            guard let anchor = presenter.anchor else { return }
            presenter.makeMenu(chooseFile: chooseFile, choosePhoto: choosePhoto,
                wallpapers: chooseWallpaper == nil ? [] : SystemWallpaper.available(),
                chooseWallpaper: chooseWallpaper ?? { _ in })
                .popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor)
        } label: {
            HStack(spacing: 6) {
                Label(title, systemImage: "photo")
                    .frame(maxWidth: .infinity)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .lineLimit(1)
            .frame(height: 20)
        }
        .buttonStyle(.bordered)
        .background(MenuAnchor(presenter: presenter).allowsHitTesting(false).accessibilityHidden(true))
        .accessibilityLabel(title)
        .accessibilityHint("Opens the file and Photos menu")
    }

    @MainActor final class Presenter: NSObject, NSMenuDelegate {
        weak var anchor: NSView?
        private var chooseFile: () -> Void = {}
        private var choosePhoto: () -> Void = {}
        private var chooseWallpaper: (URL) -> Void = { _ in }
        private var wallpapers: [SystemWallpaper] = []

        func makeMenu(chooseFile: @escaping () -> Void, choosePhoto: @escaping () -> Void,
                      wallpapers: [SystemWallpaper] = [], chooseWallpaper: @escaping (URL) -> Void = { _ in }) -> NSMenu {
            self.chooseFile = chooseFile
            self.choosePhoto = choosePhoto
            self.chooseWallpaper = chooseWallpaper
            self.wallpapers = wallpapers
            let menu = NSMenu()
            for (index, item) in [("Choose File…", "folder"), ("Photos Library…", "photo.on.rectangle")].enumerated() {
                let entry = NSMenuItem(title: item.0, action: #selector(choose(_:)), keyEquivalent: "")
                entry.image = NSImage(systemSymbolName: item.1, accessibilityDescription: nil)
                entry.tag = index
                entry.target = self
                menu.addItem(entry)
            }
            if !wallpapers.isEmpty {
                let entry = NSMenuItem(title: "System Wallpapers", action: nil, keyEquivalent: "")
                entry.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
                entry.submenu = NSMenu()
                entry.submenu?.delegate = self
                menu.addItem(entry)
            }
            return menu
        }

        /// Thumbnails are decoded only when the submenu is first opened.
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard menu.items.isEmpty else { return }
            for wallpaper in wallpapers {
                let entry = NSMenuItem(title: wallpaper.name, action: #selector(chooseWallpaper(_:)), keyEquivalent: "")
                entry.image = wallpaper.thumbnailURL.flatMap(Self.thumbnail)
                entry.representedObject = wallpaper.url
                entry.target = self
                menu.addItem(entry)
            }
        }

        /// System thumbnails never change, so each is decoded once per launch.
        private static var thumbnails: [URL: NSImage] = [:]

        private static func thumbnail(at url: URL) -> NSImage? {
            if let cached = thumbnails[url] { return cached }
            let image = makeThumbnail(at: url)
            thumbnails[url] = image
            return image
        }

        private static func makeThumbnail(at url: URL) -> NSImage? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 96
                  ] as CFDictionary) else { return nil }
            let size = NSSize(width: 36, height: 24)
            return NSImage(size: size, flipped: false) { rect in
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
                let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
                let fill = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                NSImage(cgImage: image, size: fill).draw(in: NSRect(x: rect.midX - fill.width / 2,
                    y: rect.midY - fill.height / 2, width: fill.width, height: fill.height))
                return true
            }
        }

        @objc private func chooseWallpaper(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL { chooseWallpaper(url) }
        }

        @objc private func choose(_ sender: NSMenuItem) {
            if sender.tag == 0 { chooseFile() }
            if sender.tag == 1 { choosePhoto() }
        }
    }
}

private struct MenuAnchor: NSViewRepresentable {
    let presenter: ImageSourceMenu.Presenter
    func makeNSView(context: Context) -> ImageMenuAnchorView {
        let view = ImageMenuAnchorView()
        presenter.anchor = view
        return view
    }
    func updateNSView(_ view: ImageMenuAnchorView, context: Context) {
        presenter.anchor = view
    }
}

final class ImageMenuAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
