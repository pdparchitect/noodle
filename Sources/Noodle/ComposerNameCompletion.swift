import AppKit
import SwiftUI
import NoodleCore

@MainActor
final class ComposerNameCompletion: NSObject, ObservableObject {
    static let descriptionsDefaultsKey = "Noodle.composer.showBotDescriptions"
    private weak var editor: NSTextView?
    private weak var anchor: NSView?
    private var menu: NSMenu?
    private var agents: [AgentRecord] = []
    private var preferredIDs: Set<UUID> = []
    private var separatesPreferredAgents = false
    private var showDescriptions = true
    private var dismissedRequest: AgentNameCompletion?
    private var observers: [NSObjectProtocol] = []
    private var returnKeyMonitor: Any?
    private var presentationScheduled = false

    func attach(to editor: NSTextView, anchor: NSView, agents: [AgentRecord], preferredIDs: Set<UUID>, separatesPreferredAgents: Bool = false, showDescriptions: Bool) {
        self.agents = agents
        self.preferredIDs = preferredIDs
        self.separatesPreferredAgents = separatesPreferredAgents
        self.showDescriptions = showDescriptions
        if self.editor !== editor {
            detach()
            self.editor = editor
            returnKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.menu == nil, let editor = self.editor,
                      event.window === editor.window, editor.window?.firstResponder === editor else { return event }
                return Self.insertLineBreak(for: event, in: editor) ? nil : event
            }
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
        if let returnKeyMonitor { NSEvent.removeMonitor(returnKeyMonitor) }
        returnKeyMonitor = nil
        menu?.cancelTracking()
        menu = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        editor = nil
        anchor = nil
        dismissedRequest = nil
    }

    /// Preserve native editing, selection replacement and undo. Plain Return is
    /// left to SwiftUI's onSubmit; marked text and menu tracking keep native keys.
    static func insertLineBreak(for event: NSEvent, in editor: NSTextView) -> Bool {
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.intersection([.shift, .control, .option, .command]) == .shift,
              !editor.hasMarkedText(), editor.isEditable else { return false }
        editor.insertText("\n", replacementRange: editor.selectedRange())
        return true
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
        picker.minimumWidth = showDescriptions ? 360 : 220
        let separatorIndex = separatesPreferredAgents ? candidates.firstIndex { !preferredIDs.contains($0.id) } : nil
        for (index, agent) in candidates.enumerated() {
            if index > 0, index == separatorIndex {
                picker.addItem(.separator())
            }
            let item = NSMenuItem(title: Self.menuTitle(for: agent, showDescriptions: showDescriptions),
                                  action: #selector(selectName(_:)), keyEquivalent: "")
            if showDescriptions {
                let title = NSMutableAttributedString(string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                let descriptionStart = (agent.displayName as NSString).length
                if title.length > descriptionStart {
                    title.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                       range: NSRange(location: descriptionStart, length: title.length - descriptionStart))
                }
                item.attributedTitle = title
            }
            item.target = self
            item.representedObject = agent.displayName
            if showDescriptions { item.toolTip = agent.publicDescription }
            item.image = Self.menuAvatar(for: agent)
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

    static func menuTitle(for agent: AgentRecord, showDescriptions: Bool) -> String {
        guard showDescriptions, let description = agent.publicDescription else { return agent.displayName }
        let summary = description.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !summary.isEmpty else { return agent.displayName }
        let shortened = summary.count > 72 ? String(summary.prefix(72)) + "…" : summary
        return "\(agent.displayName)  \(shortened)"
    }

    static func menuAvatar(for agent: AgentRecord) -> NSImage? {
        BotAvatar.menuImage(for: agent)
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
    @AppStorage(ComposerNameCompletion.descriptionsDefaultsKey) private var showDescriptions = true
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
            completion.attach(to: editor, anchor: view, agents: agents, preferredIDs: preferredIDs,
                              showDescriptions: showDescriptions)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ComposerNameCompletion) {
        coordinator.detach()
    }
}
