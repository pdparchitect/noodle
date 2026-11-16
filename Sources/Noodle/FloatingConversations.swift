import AppKit
import SwiftUI
import Observation

/// Conversation windows the user keeps above other apps. The set survives
/// relaunch, so a restored window floats again.
@MainActor @Observable final class FloatingConversations {
    static let shared = FloatingConversations()
    static let defaultsKey = "Noodle.floatingConversations.v1"
    static let keepsOneDefaultsKey = "Noodle.floatingConversations.keepsOne"
    private let defaults: UserDefaults
    private(set) var ids: Set<UUID>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set((defaults.stringArray(forKey: Self.defaultsKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Settings > Chat. Off by default, so several conversations may float at once.
    var keepsOne: Bool { defaults.bool(forKey: Self.keepsOneDefaultsKey) }

    func set(_ floating: Bool, for id: UUID) {
        if floating { ids.insert(id) } else { ids.remove(id) }
        persist()
    }

    func retain(_ known: Set<UUID>) {
        guard !ids.isSubset(of: known) else { return }
        ids.formIntersection(known)
        persist()
    }

    private func persist() {
        if ids.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) }
        else { defaults.set(ids.map(\.uuidString).sorted(), forKey: Self.defaultsKey) }
    }
}

/// One floating panel per conversation. The panels host the same view as a separate window.
@MainActor final class FloatingConversationPanels: NSObject, NSWindowDelegate {
    private let floating: FloatingConversations
    private let isTerminating: () -> Bool
    /// Calls or hangs up in a conversation, for the call shortcut typed in a panel.
    private let toggleCall: (UUID?) -> Void
    private let content: (UUID, FloatingPanelCommands) -> NSView
    /// Whether each panel keeps its own frame, for an app without a window registry that keeps it.
    private let savesFrames: Bool
    private var panels: [UUID: FloatingConversationPanel] = [:]

    init(floating: FloatingConversations, isTerminating: @escaping () -> Bool, toggleCall: @escaping (UUID?) -> Void = { _ in },
         savesFrames: Bool = false, content: @escaping (UUID, FloatingPanelCommands) -> NSView) {
        self.floating = floating; self.isTerminating = isTerminating; self.toggleCall = toggleCall
        self.savesFrames = savesFrames; self.content = content
    }

    private static func frameName(_ id: UUID) -> String { "FloatingConversation-\(id.uuidString)" }

    /// Whether the panel kept a frame of its own from an earlier float.
    func hasSavedFrame(_ id: UUID) -> Bool {
        savesFrames && UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameName(id))") != nil
    }

    /// Floats the conversation: shrunk from the window it replaces, or else where it last floated, or else
    /// beside the pointer.
    func float(_ id: UUID, replacing replaced: NSRect?, hasSavedFrame: Bool) {
        let visible = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
        var landing: NSRect?
        if let replaced, let visible {
            landing = FloatingConversationPanel.compactFrame(from: replaced, visible: visible)
        } else if !hasSavedFrame, let visible {
            landing = FloatingConversationPanel.landingFrame(near: NSEvent.mouseLocation, visible: visible)
        }
        show(id, frame: landing) { $0.makeKeyAndOrderFront(nil) }
    }

    func panel(for id: UUID) -> NSPanel? { panels[id] }
    var openIDs: Set<UUID> { Set(panels.keys) }

    /// A nil frame leaves placement to the saved frame the window registry restores.
    @discardableResult func show(_ id: UUID, frame: NSRect?, present: (NSPanel) -> Void) -> NSPanel {
        floating.set(true, for: id)
        if floating.keepsOne {
            // Closing mutates `panels`, so work from a copy.
            let others = panels.filter { $0.key != id }.map(\.value)
            let place = (others.first(where: \.isKeyWindow) ?? others.first)?.frame
            others.forEach { $0.close() }
            // The next conversation takes over the open float's exact place and size.
            if panels[id] == nil, let place { return open(id, frame: place, present: present) }
        }
        if let panel = panels[id] {
            present(panel)
            NotificationCenter.default.post(name: .focusConversationComposer, object: id)
            return panel
        }
        // Several floats opened from the same spot must not hide each other.
        let staggered = frame.map { requested in
            let visible = (NSScreen.screens.first { $0.frame.intersects(requested) } ?? NSScreen.main)?.visibleFrame ?? requested
            return FloatingConversationPanel.staggered(requested, avoiding: panels.values.map(\.frame), visible: visible)
        }
        return open(id, frame: staggered, present: present)
    }

    private func open(_ id: UUID, frame: NSRect?, present: (NSPanel) -> Void) -> NSPanel {
        let panel = FloatingConversationPanel.make(frame: frame ?? NSRect(origin: .zero, size: FloatingConversationPanel.compactSize))
        if frame == nil { panel.center() }
        // Restored from where it last floated, unless asked to land somewhere.
        if savesFrames { _ = panel.setFrameAutosaveName(Self.frameName(id)); if let frame { panel.setFrame(frame, display: false) } }
        panel.conversationID = id
        panel.toggleCall = toggleCall
        panel.delegate = self
        panel.contentView = content(id, panel.commands)
        panels[id] = panel
        present(panel)
        return panel
    }

    func close(_ id: UUID) { panels[id]?.close() }

    /// Stops the conversation floating, its panel open or not.
    func unfloat(_ id: UUID) {
        floating.set(false, for: id)
        close(id)
    }

    /// A hosted SwiftUI view can reset the window's own minimum, so the delegate holds it.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: FloatingConversationPanel.minimumSize)).size
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? FloatingConversationPanel, let id = panel.conversationID else { return }
        panels[id] = nil
        // Closing ends floating mode, so the conversation next opens as a normal window.
        if !isTerminating() { floating.set(false, for: id) }
    }
}

/// Only a non-activating panel may join another app's full-screen Space, and it
/// takes typing without bringing Noodle forward.
final class FloatingConversationPanel: NSPanel {
    static let compactSize = NSSize(width: 420, height: 560)
    static let minimumSize = NSSize(width: 380, height: 360)
    var conversationID: UUID?
    var toggleCall: (UUID?) -> Void = { _ in }
    /// The panel is not a scene, so its chat's menu commands arrive here and the panel runs their shortcuts.
    let commands = FloatingPanelCommands()
    var bindings = KeyboardBindings.shared
    override var canBecomeKey: Bool { true }
    // An attachment preview makes its host main, and AppKit throws if the host refuses.
    override var canBecomeMain: Bool { true }

    /// Starts a voice message, waiting for the chat to mount if the panel has just opened.
    func recordVoiceMessage() {
        commands.whenRecordingReady { [weak self] command in
            guard let self else { return }
            command.perform(in: self, bindings: bindings)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, bindings.matches(.recordVoice, event: event), let command = commands.voiceRecording {
            command.perform(in: self, bindings: bindings)
            return true
        }
        if event.type == .keyDown, bindings.matches(.call, event: event) {
            if !event.isARepeat { toggleCall(conversationID) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func make(frame: NSRect) -> FloatingConversationPanel {
        let panel = FloatingConversationPanel(contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(frame, display: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        // The chat view draws the centred title; the native one would repeat it.
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentMinSize = minimumSize
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        return panel
    }

    /// Shrinks towards the top-right corner, where the window controls sit furthest from the work.
    static func compactFrame(from frame: NSRect, visible: NSRect) -> NSRect {
        let size = NSSize(width: min(compactSize.width, frame.width), height: min(compactSize.height, frame.height))
        return clamp(NSRect(x: frame.maxX - size.width, y: frame.maxY - size.height, width: size.width, height: size.height), to: visible)
    }

    static func landingFrame(near point: NSPoint, visible: NSRect) -> NSRect {
        clamp(NSRect(x: point.x - compactSize.width / 2, y: point.y - compactSize.height / 2,
                     width: compactSize.width, height: compactSize.height), to: visible)
    }

    /// Steps down and to the right, like new document windows, until no open panel starts at the same corner.
    static func staggered(_ frame: NSRect, avoiding others: [NSRect], visible: NSRect) -> NSRect {
        var candidate = frame
        for _ in 0..<12 {
            guard others.contains(where: { abs($0.minX - candidate.minX) < 20 && abs($0.maxY - candidate.maxY) < 20 }) else { break }
            let next = clamp(candidate.offsetBy(dx: 28, dy: -28), to: visible)
            // Against the screen edge there is nowhere further to step.
            if next.origin == candidate.origin { candidate = clamp(frame.offsetBy(dx: -28 * CGFloat(others.count), dy: 0), to: visible); break }
            candidate = next
        }
        return candidate
    }

    private static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        return frame
    }
}

/// Blurs what is behind a floating conversation in place of its wallpaper.
struct FloatingWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension Notification.Name {
    /// The object is the conversation ID whose separate or floating window should return to its input.
    static let focusConversationComposer = Notification.Name("Noodle.focusConversationComposer")
}
