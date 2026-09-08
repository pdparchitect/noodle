import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Uses a real menu and checks the clipboard when opened, without polling it.
struct ComposerAttachmentMenu: NSViewRepresentable {
    @Binding var isPresented: Bool
    let attachFile: () -> Void
    let choosePhoto: () -> Void
    let pasteImage: () -> Void

    func makeNSView(context: Context) -> MenuAnchor { MenuAnchor() }

    func updateNSView(_ view: MenuAnchor, context: Context) {
        guard isPresented, !view.isOpening else { return }
        view.isOpening = true
        DispatchQueue.main.async {
            defer {
                view.isOpening = false
                isPresented = false
            }
            guard view.window != nil else { return }
            view.show(configuration: self)
        }
    }

    final class MenuAnchor: NSView {
        var isOpening = false
        private var selectedAction: (() -> Void)?
        private var actions: [() -> Void] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func show(configuration: ComposerAttachmentMenu) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            actions = [configuration.attachFile, configuration.choosePhoto, configuration.pasteImage]
            selectedAction = nil
            for (index, entry) in [("Attach File…", "doc"), ("Choose Photo…", "photo.on.rectangle"),
                                   ("Paste Image", "doc.on.clipboard")].enumerated() {
                let item = NSMenuItem(title: entry.0, action: #selector(selectItem(_:)), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: nil)
                item.target = self
                item.tag = index
                if index == 2 { item.isEnabled = ImageAttachmentPasteboard.canPasteImage() }
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY + 5), in: self)
            let action = selectedAction
            selectedAction = nil
            actions = []
            // File and Photos panels must open after menu tracking finishes.
            if let action { DispatchQueue.main.async(execute: action) }
        }

        @objc private func selectItem(_ item: NSMenuItem) {
            guard actions.indices.contains(item.tag) else { return }
            selectedAction = actions[item.tag]
        }
    }
}

enum ImageAttachmentPasteboard {
    static func canPasteImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.availableType(from: [.png, .tiff]) != nil || !imageFileURLs(pasteboard).isEmpty
    }

    static func imageFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension)
            return type?.conforms(to: .image) == true
        }
    }
}
