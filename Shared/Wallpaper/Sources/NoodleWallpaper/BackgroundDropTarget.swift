import AppKit
import SwiftUI
import NoodleWallpaperCore

public extension View {
    /// Make the whole preview accept media, including wallpaper views that ignore input, dropped or pasted:
    /// ⌘V or Paste in its menu, which go to the sheet rather than the conversation behind it.
    func backgroundDropTarget(isBusy: Binding<Bool>, failure: Binding<String?>,
                              onLoad: @escaping (PreparedBackgroundFile) -> Void) -> some View {
        modifier(BackgroundDropTarget(isBusy: isBusy, failure: failure, onLoad: onLoad))
    }
}

private struct BackgroundDropTarget: ViewModifier {
    @Binding var isBusy: Bool
    @Binding var failure: String?
    let onLoad: (PreparedBackgroundFile) -> Void
    @State private var isTargeted = false
    @State private var importTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.overlay {
            Color.clear
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .onDrop(of: BackgroundDrop.contentTypes, isTargeted: $isTargeted, perform: drop)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isTargeted && !isBusy ? Color.accentColor : .clear, lineWidth: 3)
                .allowsHitTesting(false)
        }
        .overlay { BackgroundPasteTarget(isBusy: isBusy, paste: load) }
        .help("Drop or paste an image, video or Metal shader to use as the background")
        .onDisappear { importTask?.cancel(); importTask = nil }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !isBusy, let provider = providers.first(where: BackgroundDrop.accepts) else { return false }
        load(provider)
        return true
    }

    private func load(_ provider: NSItemProvider) {
        guard !isBusy else { return }
        isBusy = true
        failure = nil
        importTask = Task { @MainActor in
            defer { isBusy = false }
            do {
                let file = try await BackgroundDrop.load(provider)
                try Task.checkCancellation()
                onLoad(file)
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

extension BackgroundPaste {
    /// What Paste takes from `pasteboard`, as a drop would take it, or nil when nothing on it can be a background.
    @MainActor static func item(from pasteboard: NSPasteboard) -> NSItemProvider? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let providers = (pasteboard.pasteboardItems ?? []).map { copied in
            // Read only when loaded, as a drop is; the item is not touched anywhere else meanwhile.
            nonisolated(unsafe) let item = copied
            let provider = NSItemProvider()
            for type in item.types {
                provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                    completion(item.data(forType: type), nil)
                    return nil
                }
            }
            return provider
        }
        return item(fileURLs: files, providers: providers)
    }
}

/// Takes Paste for the preview: Edit › Paste and ⌘V while its sheet is open, and Paste in its menu.
private struct BackgroundPasteTarget: NSViewRepresentable {
    let isBusy: Bool
    let paste: (NSItemProvider) -> Void

    func makeNSView(context: Context) -> BackgroundPasteView { BackgroundPasteView() }

    func updateNSView(_ view: BackgroundPasteView, context: Context) {
        view.isBusy = isBusy
        view.onPaste = paste
    }
}

final class BackgroundPasteView: NSView, NSMenuItemValidation {
    /// Replaced by tests, which never touch the clipboard.
    @MainActor static var pasteboard = NSPasteboard.general
    var isBusy = false
    var onPaste: (NSItemProvider) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }

    /// The sheet's own first responder, so Paste reaches it before the conversation in the window behind,
    /// which would otherwise attach what was copied. A control that has focus keeps it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if let current = window.firstResponder as? NSView, current !== self, !self.isDescendant(of: current) { return }
            window.makeFirstResponder(self)
        }
    }

    /// Only the menu: drops, clicks and the help tag belong to the preview beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
        return super.hitTest(point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc func paste(_ sender: Any?) {
        guard !isBusy, let item = BackgroundPaste.item(from: Self.pasteboard) else { return NSSound.beep() }
        onPaste(item)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(paste(_:)) else { return true }
        return !isBusy && BackgroundPaste.item(from: Self.pasteboard) != nil
    }
}
