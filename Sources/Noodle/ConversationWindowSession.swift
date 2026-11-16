import AppKit
import SwiftUI

/// UI state lives beside the workspace, keeping development and production separate.
/// Checkpoint each change so restoration does not depend on a clean application exit.
@MainActor final class ConversationWindowSession {
    private let fileURL: URL?
    private(set) var frames: [UUID: String]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let frames = try? JSONDecoder().decode([UUID: String].self, from: data) {
            self.frames = frames
        } else {
            frames = [:]
        }
    }

    func save(frame: String, for id: UUID) {
        var updated = frames
        updated[id] = frame
        persist(updated)
    }

    func remove(_ id: UUID) {
        var updated = frames
        updated.removeValue(forKey: id)
        persist(updated)
    }

    func retainConversations(_ ids: Set<UUID>) {
        persist(frames.filter { ids.contains($0.key) })
    }

    private func persist(_ updated: [UUID: String]) {
        guard updated != frames else { return }
        do {
            if let fileURL {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            }
            frames = updated
        } catch {
            NSLog("Could not save conversation windows: %@", error.localizedDescription)
        }
    }
}

/// Weak mounts identify real conversation windows without retaining closed scenes
/// or treating Settings, previews, and minimized windows as a viewed conversation.
@MainActor final class ConversationWindowRegistry: NSObject {
    fileprivate let hosts = NSHashTable<ConversationWindowHost.Probe>.weakObjects()
    private let session: ConversationWindowSession
    private var knownConversationIDs: Set<UUID>?
    private var hasRestoredWindows = false
    private(set) var isTerminating = false
    private var openSeparateWindow: ((UUID) -> Void)?
    /// A panel is outside every scene, so the main scene leaves its opener here.
    var openMainWindow: (() -> Void)?

    init(fileURL: URL? = nil) {
        session = ConversationWindowSession(fileURL: fileURL)
        super.init()
    }

    func retainConversations(_ ids: Set<UUID>) {
        knownConversationIDs = ids
        session.retainConversations(ids)
    }

    func restoreWindows(openWindow: @escaping (UUID) -> Void) {
        // The main window's host selects in place, so panels and floating need the scene's own opener.
        openSeparateWindow = openWindow
        guard !hasRestoredWindows else { return }
        hasRestoredWindows = true
        for id in session.frames.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            // The main window can display this same conversation independently.
            guard !hosts.allObjects.contains(where: { !$0.isMainWindow && $0.conversationID == id }) else { continue }
            openWindow(id)
        }
    }

    func prepareForTermination() {
        // AppKit closing windows during Quit must not look like explicit closes.
        isTerminating = true
    }

    fileprivate func checkpoint(_ host: ConversationWindowHost.Probe) {
        guard !isTerminating, !host.isClosed, !host.isMainWindow, !host.isRestoringFrame,
              let id = host.conversationID, let window = host.window,
              knownConversationIDs?.contains(id) != false else { return }
        if host.restoredConversationID != id {
            host.restoredConversationID = id
            if let frame = session.frames[id] {
                host.isRestoringFrame = true
                window.setFrame(from: frame)
                window.setFrame(window.constrainFrameRect(window.frame, to: window.screen ?? NSScreen.main), display: false)
                host.isRestoringFrame = false
            }
        }
        // Keep the normal frame while a window is full screen.
        guard !window.styleMask.contains(.fullScreen) else { return }
        session.save(frame: window.frameDescriptor, for: id)
    }

    fileprivate func closed(_ host: ConversationWindowHost.Probe) {
        hosts.remove(host)
        guard !isTerminating, !host.isMainWindow, let id = host.conversationID,
              !hosts.allObjects.contains(where: { !$0.isMainWindow && $0.conversationID == id }) else { return }
        session.remove(id)
    }

    func isViewing(_ conversationID: UUID) -> Bool {
        NSApp.isActive && hosts.allObjects.contains {
            $0.conversationID == conversationID && $0.window.map {
                $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
            } == true
        }
    }

    @discardableResult func focus(_ conversationID: UUID, separateOnly: Bool = false) -> Bool {
        let matches = hosts.allObjects.filter { $0.conversationID == conversationID && !(separateOnly && $0.isMainWindow) }
        guard let host = matches.first(where: { !$0.isMainWindow }) ?? matches.first,
              let window = host.window else { return false }
        show(window)
        host.markRead?(conversationID)
        return true
    }

    /// The conversation a window shows, so menu commands can act on the key window's chat.
    func conversationID(in window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return hosts.allObjects.first { !$0.isClosed && $0.window === window }?.conversationID
    }

    /// Closes the conversation's normal separate window and returns the frame it had.
    func closeSeparateWindow(_ conversationID: UUID) -> NSRect? {
        guard let window = hosts.allObjects.first(where: {
            !$0.isMainWindow && $0.conversationID == conversationID && !($0.window is FloatingConversationPanel)
        })?.window else { return nil }
        let frame = window.frame
        window.close()
        return frame
    }

    func hasSavedFrame(_ conversationID: UUID) -> Bool { session.frames[conversationID] != nil }

    /// Opens or raises the conversation's separate window and puts the caret in its input.
    func present(_ conversationID: UUID) {
        if focus(conversationID, separateOnly: true) {
            NotificationCenter.default.post(name: .focusConversationComposer, object: conversationID)
            return
        }
        openSeparateWindow?(conversationID)
    }

    /// Raises the main window, opening it again if it was closed.
    func showMainWindow() {
        if let window = hosts.allObjects.first(where: { $0.isMainWindow && !$0.isClosed })?.window { show(window) }
        else { openMainWindow?() }
    }

    /// Floats the conversation in `panels`, in place of its normal separate window if one is open.
    func float(_ conversationID: UUID, in panels: FloatingConversationPanels, from frame: NSRect? = nil) {
        let replaced = closeSeparateWindow(conversationID)
        panels.float(conversationID, replacing: frame ?? replaced, hasSavedFrame: hasSavedFrame(conversationID))
    }

    /// Opens the conversation in a normal separate window, in place of its floating panel if one is open.
    func dock(_ conversationID: UUID, panels: FloatingConversationPanels) {
        panels.unfloat(conversationID)
        present(conversationID)
    }

    /// Shows the conversation in the main window, chosen there by `select`, and closes its separate window and panel.
    func returnToMainWindow(_ conversationID: UUID, panels: FloatingConversationPanels, select: (UUID) -> Void) {
        select(conversationID)
        // The main window comes forward first, so the app never passes through having no window.
        showMainWindow()
        panels.close(conversationID)
        _ = closeSeparateWindow(conversationID)
    }

    private func show(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct ConversationWindowHost: NSViewRepresentable {
    let registry: ConversationWindowRegistry
    let conversationID: UUID?
    var isMainWindow = false
    /// The window's title, with the app's plain titlebar; nil leaves the window as the app styles it.
    var title: String? = nil
    let markRead: (UUID?) -> Void

    func makeNSView(context: Context) -> Probe { Probe(registry: registry) }
    func updateNSView(_ view: Probe, context: Context) {
        view.conversationID = conversationID
        view.isMainWindow = isMainWindow
        view.title = title
        view.markRead = markRead
        DispatchQueue.main.async { [weak view] in view?.updateWindow() }
    }

    final class Probe: NSView {
        let registry: ConversationWindowRegistry
        var conversationID: UUID?
        var isMainWindow = false
        var title: String?
        var markRead: ((UUID?) -> Void)?
        fileprivate var restoredConversationID: UUID?
        fileprivate var isRestoringFrame = false
        fileprivate var isClosed = false
        private var interactionMonitor: Any?
        private static let interactionEvents: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .keyDown, .scrollWheel, .magnify, .smartMagnify, .rotate, .swipe, .pressure
        ]

        init(registry: ConversationWindowRegistry) {
            self.registry = registry
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoringInteractions()
            NotificationCenter.default.removeObserver(self)
            registry.hosts.remove(self)
            guard let window else { return }
            isClosed = false
            restoredConversationID = nil
            registry.hosts.add(self)
            interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.interactionEvents) { [weak self] event in
                self?.handleInteraction(event)
                return event
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(markVisibleRead), name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(markVisibleRead),
                name: NSApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(checkpoint), name: name, object: window)
            }
            DispatchQueue.main.async { [weak self] in self?.updateWindow() }
        }
        func handleInteraction(_ event: NSEvent) {
            guard !isClosed, let window, let conversationID,
                  event.window === window,
                  Self.interactionEvents.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)) else { return }
            // Input in this window is direct evidence of reading. Activation and
            // occlusion notifications can still describe the previous app state.
            markRead?(conversationID)
        }
        private func stopMonitoringInteractions() {
            if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
            interactionMonitor = nil
        }
        deinit { if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) } }
        func updateWindow() {
            guard !isClosed else { return }
            // Each runs on every update, and setting even the same value makes AppKit redo the titlebar and its toolbar.
            if let window, let title {
                if window.title != title { window.title = title }
                if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
                // A floating window is see-through; FloatingWindowLevel owns its background.
                if window.level != .floating, window.backgroundColor != .windowBackgroundColor { window.backgroundColor = .windowBackgroundColor }
            }
            checkpoint()
            markVisibleRead()
        }
        @objc private func checkpoint() { registry.checkpoint(self) }
        @objc private func markVisibleRead() {
            guard !isClosed else { return }
            if window?.isVisible == true { registry.hosts.add(self) }
            if let conversationID, registry.isViewing(conversationID) { markRead?(conversationID) }
        }
        @objc private func closed() {
            isClosed = true
            stopMonitoringInteractions()
            registry.closed(self)
        }
    }
}
