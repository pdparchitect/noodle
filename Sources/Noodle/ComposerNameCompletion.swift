import AppKit
import SwiftUI
import NoodleCore

@MainActor
final class ComposerNameCompletion: NSObject, ObservableObject {
    private weak var editor: NSTextView?
    private weak var anchor: NSView?
    private var menu: NSMenu?
    private var agents: [AgentRecord] = []
    private var preferredIDs: Set<UUID> = []
    private var dismissedRequest: AgentNameCompletion?
    private var observers: [NSObjectProtocol] = []
    private var presentationScheduled = false

    func attach(to editor: NSTextView, anchor: NSView, agents: [AgentRecord], preferredIDs: Set<UUID>) {
        self.agents = agents
        self.preferredIDs = preferredIDs
        if self.editor !== editor {
            detach()
            self.editor = editor
            for notification in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: notification, object: editor, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleMenu() }
                })
            }
        }
        self.anchor = anchor
        editor.isContinuousSpellCheckingEnabled = true
        editor.isGrammarCheckingEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = true
        scheduleMenu()
    }

    func detach() {
        menu?.cancelTracking()
        menu = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        editor = nil
        anchor = nil
        dismissedRequest = nil
    }

    private func scheduleMenu() {
        guard menu == nil, !presentationScheduled else { return }
        presentationScheduled = true
        // Finish the text edit and SwiftUI binding update before entering native
        // menu tracking. AppKit owns drawing, selection and keyboard handling.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            self.showMenu()
        }
    }

    private func showMenu() {
        guard menu == nil, let editor, let anchor, let window = anchor.window,
              editor.window === window, window.firstResponder === editor,
              !editor.hasMarkedText() else { return }
        guard let request = AgentNameCompletion.request(in: editor.string, selection: editor.selectedRange()) else {
            dismissedRequest = nil
            return
        }
        guard request != dismissedRequest else { return }
        let candidates = request.matches(agents, preferredIDs: preferredIDs)
        guard !candidates.isEmpty else { return }

        let picker = NSMenu(title: "Bot names")
        picker.autoenablesItems = false
        for agent in candidates {
            let item = NSMenuItem(title: agent.displayName, action: #selector(selectName(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.displayName
            let image = agent.avatarImageData.flatMap(NSImage.init(data:))
                ?? NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
            image?.size = NSSize(width: 16, height: 16)
            item.image = image
            picker.addItem(item)
        }

        let glyph = editor.firstRect(forCharacterRange: NSRange(location: request.range.location, length: 1), actualRange: nil)
        // Screen coordinates increase upwards. Place the native menu above @;
        // AppKit adjusts it to fit the screen, including outside the app window.
        let position = NSPoint(x: glyph.minX, y: glyph.maxY + picker.size.height + 4)
        menu = picker
        dismissedRequest = request
        let localPosition = anchor.convert(window.convertPoint(fromScreen: position), from: nil)
        picker.popUp(positioning: nil, at: localPosition, in: anchor)
        if menu === picker { menu = nil }
    }

    @objc private func selectName(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String,
              let editor, !editor.hasMarkedText(), let request = dismissedRequest,
              AgentNameCompletion.request(in: editor.string, selection: editor.selectedRange()) == request else { return }
        editor.window?.makeFirstResponder(editor)
        editor.breakUndoCoalescing()
        editor.insertText(request.replacement(name: name, in: editor.string), replacementRange: request.range)
        editor.breakUndoCoalescing()
    }
}

/// Keeps SwiftUI's existing multiline field, including undo, paste and spelling.
struct ChatComposerBridge: NSViewRepresentable {
    let isActive: Bool
    let draft: String
    let agents: [AgentRecord]
    let preferredIDs: Set<UUID>
    let completion: ComposerNameCompletion

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func makeCoordinator() -> ComposerNameCompletion { completion }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard isActive else { completion.detach(); return }
            guard let editor = view.window?.firstResponder as? NSTextView,
                  editor.string == draft else { return }
            completion.attach(to: editor, anchor: view, agents: agents, preferredIDs: preferredIDs)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ComposerNameCompletion) {
        coordinator.detach()
    }
}
