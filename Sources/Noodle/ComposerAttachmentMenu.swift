import AppKit
import SwiftUI

/// Opens a native menu anchored to the composer’s existing + button.
struct ComposerAttachmentMenu: NSViewRepresentable {
    @Binding var isPresented: Bool
    let attachFile: () -> Void
    let choosePhoto: () -> Void
    let capture: () -> Void

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
            actions = [configuration.attachFile, configuration.choosePhoto, configuration.capture]
            selectedAction = nil
            for (index, entry) in [("Attach File…", "doc"), ("Choose Photo…", "photo.on.rectangle"),
                                   ("Capture…", "macwindow")].enumerated() {
                if index == 2 { menu.addItem(.separator()) }
                let item = NSMenuItem(title: entry.0, action: #selector(selectItem(_:)), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: nil)
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY + 5), in: self)
            let action = selectedAction
            selectedAction = nil
            actions = []
            // Panels must open after menu tracking finishes.
            if let action { DispatchQueue.main.async(execute: action) }
        }

        @objc private func selectItem(_ item: NSMenuItem) {
            guard actions.indices.contains(item.tag) else { return }
            selectedAction = actions[item.tag]
        }
    }
}
