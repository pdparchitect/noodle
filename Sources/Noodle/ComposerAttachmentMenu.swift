import AppKit
import NoodleCore
import PhotosUI
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
                if index == 2, KeyboardBindings.shared.recordingAction == nil,
                   let binding = KeyboardBindings.shared.binding(for: .capture) {
                    item.keyEquivalent = binding.key
                    item.keyEquivalentModifierMask = []
                    if binding.modifiers.contains(.command) { item.keyEquivalentModifierMask.insert(.command) }
                    if binding.modifiers.contains(.shift) { item.keyEquivalentModifierMask.insert(.shift) }
                    if binding.modifiers.contains(.option) { item.keyEquivalentModifierMask.insert(.option) }
                    if binding.modifiers.contains(.control) { item.keyEquivalentModifierMask.insert(.control) }
                }
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
            if item.tag == 2, let event = NSApp.currentEvent, event.type == .keyDown {
                guard !event.isARepeat else { return }
                if !event.modifierFlags.intersection([.command, .control]).isEmpty,
                   !KeyboardBindings.shared.matches(.capture, event: event) { return }
            }
            selectedAction = actions[item.tag]
        }
    }
}

/// Attach File… and Choose Photo…, in every app: what is picked goes to the conversation the picker was opened
/// for, even when another is showing by the time it closes.
struct AttachmentPickers {
    var choosingFiles = false
    var choosingPhotos = false
    var photos: [PhotosPickerItem] = []
    private(set) var destination: UUID?

    mutating func attachFile(to conversationID: UUID) {
        destination = conversationID
        choosingFiles = true
    }

    mutating func choosePhoto(for conversationID: UUID) {
        destination = conversationID
        photos = []
        choosingPhotos = true
    }

    /// Where what was picked goes, once.
    mutating func takeDestination() -> UUID? {
        defer { destination = nil }
        return destination
    }
}

extension View {
    /// The pickers, importing what is picked into its conversation; a photo that can't be read is reported, the
    /// first such problem once.
    func attachmentPickers(_ pickers: Binding<AttachmentPickers>,
                           importFiles: @escaping @MainActor ([URL], UUID) -> Void,
                           importPhoto: @escaping @MainActor (Data, UUID) throws -> Void,
                           report: @escaping @MainActor (String) -> Void) -> some View {
        fileImporter(isPresented: pickers.choosingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            let destination = pickers.wrappedValue.takeDestination()
            switch result {
            case .success(let urls): if let destination { importFiles(urls, destination) }
            case .failure(let error): report(error.localizedDescription)
            }
        }
        .photosPicker(isPresented: pickers.choosingPhotos, selection: pickers.photos, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: pickers.wrappedValue.photos) { _, items in
            guard !items.isEmpty, let destination = pickers.wrappedValue.takeDestination() else { return }
            pickers.wrappedValue.photos = []
            Task { @MainActor in
                var firstError: Error?
                for item in items {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw AttachmentTransferError.unsupportedItem
                        }
                        try importPhoto(data, destination)
                    } catch { firstError = firstError ?? error }
                }
                if let firstError { report(firstError.localizedDescription) }
            }
        }
    }
}
