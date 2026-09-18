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
    var chooseWallpaper: (() -> Void)? = nil
    @State private var presenter = Presenter()

    public init(title: String, chooseFile: @escaping () -> Void, choosePhoto: @escaping () -> Void,
                chooseWallpaper: (() -> Void)? = nil) {
        self.title = title
        self.chooseFile = chooseFile
        self.choosePhoto = choosePhoto
        self.chooseWallpaper = chooseWallpaper
    }

    public var body: some View {
        Button {
            guard let anchor = presenter.anchor else { return }
            // Offer wallpapers only while this Mac actually has some on disk.
            let wallpapers = chooseWallpaper.flatMap { SystemWallpaper.available().isEmpty ? nil : $0 }
            presenter.makeMenu(chooseFile: chooseFile, choosePhoto: choosePhoto, chooseWallpaper: wallpapers)
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

    @MainActor final class Presenter: NSObject {
        weak var anchor: NSView?
        private var actions: [() -> Void] = []

        func makeMenu(chooseFile: @escaping () -> Void, choosePhoto: @escaping () -> Void,
                      chooseWallpaper: (() -> Void)? = nil) -> NSMenu {
            var entries = [("Choose File…", "folder", chooseFile), ("Photos Library…", "photo.on.rectangle", choosePhoto)]
            if let chooseWallpaper { entries.append(("System Wallpapers…", "desktopcomputer", chooseWallpaper)) }
            actions = entries.map(\.2)
            let menu = NSMenu()
            for (index, item) in entries.enumerated() {
                let entry = NSMenuItem(title: item.0, action: #selector(choose(_:)), keyEquivalent: "")
                entry.image = NSImage(systemSymbolName: item.1, accessibilityDescription: nil)
                entry.tag = index
                entry.target = self
                menu.addItem(entry)
            }
            return menu
        }

        @objc private func choose(_ sender: NSMenuItem) {
            if actions.indices.contains(sender.tag) { actions[sender.tag]() }
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
