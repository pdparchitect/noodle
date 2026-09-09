import AppKit
import SwiftUI

/// Use the same SwiftUI bezel as Create Image; only the opened menu is AppKit.
/// Native pop-up buttons have different intrinsic sizing and bezel metrics.
struct ImageSourceMenu: View {
    let title: String
    let chooseFile: () -> Void
    let choosePhoto: () -> Void
    @State private var presenter = Presenter()

    var body: some View {
        Button {
            guard let anchor = presenter.anchor else { return }
            presenter.makeMenu(chooseFile: chooseFile, choosePhoto: choosePhoto)
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
        private var chooseFile: () -> Void = {}
        private var choosePhoto: () -> Void = {}

        func makeMenu(chooseFile: @escaping () -> Void, choosePhoto: @escaping () -> Void) -> NSMenu {
            self.chooseFile = chooseFile
            self.choosePhoto = choosePhoto
            let menu = NSMenu()
            for (index, item) in [("Choose File…", "folder"), ("Photos Library…", "photo.on.rectangle")].enumerated() {
                let entry = NSMenuItem(title: item.0, action: #selector(choose(_:)), keyEquivalent: "")
                entry.image = NSImage(systemSymbolName: item.1, accessibilityDescription: nil)
                entry.tag = index
                entry.target = self
                menu.addItem(entry)
            }
            return menu
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
