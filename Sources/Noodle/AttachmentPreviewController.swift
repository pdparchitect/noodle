import AppKit
import QuickLookUI
import ScreenCaptureKit
import SwiftUI
import Observation
import OSLog
import NoodleCore

@MainActor protocol PreviewAnnotationTarget: AnyObject {
    func annotate()
    func startRegion()
}

@MainActor @Observable final class AnnotationCommandsState {
    static let shared = AnnotationCommandsState()
    var enabled = false
    weak var owner: (any PreviewAnnotationTarget)?
    weak var conversationOwner: (any PreviewAnnotationTarget)?
    var conversationEnabled = false

    var target: (any PreviewAnnotationTarget)? { enabled ? owner : conversationEnabled ? conversationOwner : nil }
}

struct AnnotationCommands: Commands {
    private let state = AnnotationCommandsState.shared
    var body: some Commands {
        CommandMenu("Preview") {
            Button("Add Annotation…") { state.target?.annotate() }
                .appShortcut(.annotateSelection)
                .disabled(!state.enabled && !state.conversationEnabled)
            Button("Annotate Region…") { state.target?.startRegion() }
                .appShortcut(.annotateRegion)
                .disabled(!state.enabled && !state.conversationEnabled)
        }
    }
}

/// Keep one native preview owner outside the changing conversation detail.
/// Both ordinary attachments and annotations must use this same mounted owner.
struct AttachmentPreviewScope<Content: View>: View {
    let conversationID: UUID?
    @ViewBuilder var content: (AttachmentPreviewController) -> Content
    @State private var controller = AttachmentPreviewController()

    var body: some View {
        content(controller)
            .background(AttachmentPreviewHost(controller: controller))
            .onChange(of: conversationID) { _, _ in controller.close() }
            .onDisappear { controller.close() }
    }
}

/// The native view controller participates in SwiftUI's actual view hierarchy,
/// giving Quick Look a stable responder owner without replacing window delegates.
struct AttachmentPreviewHost: View {
    let controller: AttachmentPreviewController
    var body: some View {
        AttachmentPreviewMount(controller: controller)
            .id(ObjectIdentifier(controller))
    }
}

/// Key a mount to its controller so replacing the window's owner also replaces
/// the AppKit responder, even if SwiftUI reuses the surrounding view hierarchy.
private struct AttachmentPreviewMount: NSViewControllerRepresentable {
    let controller: AttachmentPreviewController
    func makeNSViewController(context: Context) -> AttachmentPreviewController { controller }
    func updateNSViewController(_ controller: AttachmentPreviewController, context: Context) {}
    static func dismantleNSViewController(_ controller: AttachmentPreviewController, coordinator: ()) { controller.detach() }
}

@MainActor private final class AttachmentPreviewHostView: NSView {
    weak var owner: AttachmentPreviewController?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { owner?.attach(to: window) } else { owner?.detach() }
    }
}

@MainActor final class AttachmentPreviewController: NSViewController,
    @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate, NSPopoverDelegate, PreviewAnnotationTarget {
    struct Pending {
        let source: ConversationAttachment
        var quote: String?
        var sourceMessageID: UUID?
        var region: AttachmentAnnotation.Region?
        var file: String { source.originalFilename }
    }
    private final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(url: URL, title: String) { previewItemURL = url; previewItemTitle = title }
    }
    private static weak var active: AttachmentPreviewController?
    private static let conversationEditors = NSHashTable<AttachmentPreviewController>.weakObjects()

    static func containsPreviewWindow(_ window: NSWindow?) -> Bool {
        if window?.identifier?.rawValue == "NoodleScreenCapture" { return true }
        if let window, conversationEditors.allObjects.contains(where: {
            window === $0.overlay || window === $0.commentPopover?.contentViewController?.view.window ||
                window === $0.closingPopover?.contentViewController?.view.window
        }) { return true }
        guard let window, let owner = active else { return false }
        return window === owner.panel || window === owner.overlay ||
            window === owner.annotationPreview.window ||
            window === owner.commentPopover?.contentViewController?.view.window ||
            window === owner.closingPopover?.contentViewController?.view.window
    }
    private weak var hostWindow: NSWindow?
    private weak var previewResponder: NSResponder?
    private weak var hostResponder: NSResponder?
    private var item: Item?
    private var source: ConversationAttachment?
    private var save: ((AttachmentAnnotation, Data, ConversationAttachment) throws -> Void)?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var isDismissing = false
    private var openedAt = Date.distantPast
    private var monitor: Any?
    private var annotationEscapeDown = false
    private var windowSession: PreviewWindowSession?
    private let lifecycleLog = Logger(subsystem: "com.pdparchitect.noodle", category: "AttachmentPreview")
    let annotationPreview = AnnotationPreviewController()
    var panel: QLPreviewPanel?
    private weak var conversationWindow: NSWindow?
    var annotationWindow: NSWindow? { conversationWindow ?? panel }
    var isConversationAnnotation: Bool { conversationWindow != nil }
    var conversationCanvas: AnnotationRegionCanvas?
    var onAnnotationStateChange: (() -> Void)?
    var hasPendingAnnotation: Bool { busy || pending != nil || commentPanel != nil || closingPopover != nil || overlay != nil || conversationCanvas != nil }
    var commentPanel: NSPanel?
    var commentPopover: NSPopover?
    private var closingPopover: NSPopover?
    private var finishAfterPopoverClose: (() -> Void)?
    var overlay: NSPanel?
    var commentInput: NSTextView?
    var pending: Pending?
    var pendingImage: NSImage?
    var textAnchorInPreview: NSPoint?
    private var lastPointerInPreview: NSPoint?
    var busy = false { didSet { updateCommands() } }

    var currentURL: URL? { item?.previewItemURL }
    var canAnnotate: Bool {
        source != nil && panel?.isVisible == true && NSApp.keyWindow === panel && ownsPanel &&
            !busy && commentPanel == nil && closingPopover == nil && overlay == nil && NSApp.modalWindow == nil && panel?.attachedSheet == nil
    }
    private var ownsPanel: Bool {
        guard let panel else { return false }
        return panel.currentController as? AttachmentPreviewController === self
    }

    override func loadView() {
        let host = AttachmentPreviewHostView(frame: .zero)
        host.owner = self
        view = host
    }
    func attach(to window: NSWindow) {
        guard hostWindow !== window else { return }
        close()
        hostWindow = window
    }
    func detach() {
        close()
        hostWindow = nil
    }
    func resolveHostWindow() -> NSWindow? {
        // Resolve the live hierarchy even after a SwiftUI remount that did not
        // deliver a distinct viewDidMoveToWindow callback.
        if isViewLoaded, let window = view.window { attach(to: window) }
        return hostWindow
    }
    func show(_ attachment: ConversationAttachment, url: URL,
              edit: ((ConversationAttachment, String) throws -> ConversationAttachment)? = nil,
              canEdit: @escaping (ConversationAttachment) -> Bool = { _ in false },
              save: @escaping (AttachmentAnnotation, Data, ConversationAttachment) throws -> Void) {
        guard let hostWindow = resolveHostWindow() else { return }
        trace("show requested")
        if Self.active !== self { Self.active?.close() }
        if attachment.annotation != nil {
            close()
            Self.active = self
            annotationPreview.show(attachment, url: url, relativeTo: hostWindow, edit: edit, canEdit: canEdit)
            updateCommands()
            return
        }
        annotationPreview.close()
        dismissAnnotation()
        guard let preview = QLPreviewPanel.shared() else { return }
        let reusingPreview = preview.isVisible && ownsPanel && windowSession != nil
        if currentURL != url { lastPointerInPreview = nil }
        // QL searches the responder chain during key/main-window changes. Its
        // requested item must already exist before that search starts.
        Self.active = self
        source = attachment; item = Item(url: url, title: attachment.originalFilename); self.save = save
        panel = preview
        if !reusingPreview {
            if hostWindow.firstResponder !== view { hostResponder = hostWindow.firstResponder }
            hostWindow.makeKeyAndOrderFront(nil)
            hostWindow.makeMain()
            hostWindow.makeFirstResponder(view)
        }
        // Do not activate the host when switching items in a visible preview:
        // Quick Look can close in response, invalidating the new item mid-open.
        if windowSession == nil {
            windowSession = PreviewWindowSession(window: preview) { [weak self] in
                self?.finishPreviewSession()
            }
        }
        if !reusingPreview {
            // We just changed the host's first responder. Acquire control and
            // restore the data source before showing a previously closed panel.
            preview.updateController()
            if !ownsPanel {
                preview.makeKeyAndOrderFront(nil)
                if !ownsPanel { preview.updateController() }
            }
        }
        guard ownsPanel else { close(); return }
        // A closed shared panel can retain its controller while its data source
        // was cleared by the close/handoff. Rebind on every successful open.
        configurePreviewPanel(preview)
        preview.reloadData(); preview.currentPreviewItemIndex = 0; preview.refreshCurrentPreviewItem()
        preview.title = attachment.originalFilename
        openedAt = Date()
        preview.makeKeyAndOrderFront(nil)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown],
                handler: eventMonitorHandler())
        }
        updateCommands()
    }
    /// Use the shared editor with an in-memory conversation source. Nothing is
    /// persisted until Save, and this session never acquires Quick Look control.
    func annotateConversation(in window: NSWindow, source: ConversationAttachment, quote: String?,
                              messageID: UUID? = nil, snapshot: NSImage? = nil,
                              save: @escaping (AttachmentAnnotation, Data, ConversationAttachment) throws -> Void) {
        close()
        conversationWindow = window
        Self.conversationEditors.add(self)
        previewResponder = window.firstResponder
        self.save = save
        pending = Pending(source: source, quote: quote, sourceMessageID: messageID)
        pendingImage = snapshot
        textAnchorInPreview = AnnotationPopoverAnchor.point(in: window.frame,
            screenPointer: NSEvent.mouseLocation, lastPoint: nil)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: eventMonitorHandler())
        }
        if let snapshot { showRegion(image: snapshot, frame: window.frame) }
        else { showComment() }
    }

    func close() {
        trace("close requested")
        annotationPreview.close()
        if ownsPanel, let windowSession {
            windowSession.close()
        } else {
            finishPreviewSession()
        }
    }
    private func finishPreviewSession() {
        trace("session finished")
        windowSession?.invalidate(); windowSession = nil
        dismissAnnotation()
        // This also runs inside the native close notification. Do not order
        // out, show, or reconfigure QL here: its own close is already underway.
        // Native endPreviewPanelControl is responsible for releasing bindings.
        item = nil; source = nil; save = nil; conversationWindow = nil
        Self.conversationEditors.remove(self)
        lastPointerInPreview = nil
        if hostWindow?.firstResponder === view { hostWindow?.makeFirstResponder(hostResponder) }
        hostResponder = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        annotationEscapeDown = false
        if Self.active === self { Self.active = nil }
        updateCommands()
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { item != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        trace("native control acquired")
        configurePreviewPanel(panel)
    }
    func configurePreviewPanel(_ panel: QLPreviewPanel) {
        self.panel = panel; panel.dataSource = self; panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        releasePreviewPanel(panel)
    }
    func releasePreviewPanel(_ panel: QLPreviewPanel) {
        trace("native control released")
        if panel.dataSource as? AttachmentPreviewController === self { panel.dataSource = nil }
        if panel.delegate as? AttachmentPreviewController === self { panel.delegate = nil }
        // QL can order out without NSWindow.willClose. End that session without
        // issuing another close; never clean up a visible control handoff.
        let token = generation
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.generation == token, Self.active === self,
                  self.windowSession != nil, !panel.isVisible else { return }
            self.finishPreviewSession()
        }
        updateCommands()
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { item == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem { item! }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool { false }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel { previewWillStartClosing() }
        return true
    }
    private func previewWillStartClosing() {
        trace("native close starting")
        // Cancel a queued annotation focus return before the native fade, when
        // isVisible may still be true. Do not start another window operation.
        generation = UUID(); operation?.cancel(); operation = nil
    }
    func windowDidBecomeKey(_ notification: Notification) { updateCommands() }
    func windowDidResignKey(_ notification: Notification) { updateCommands() }
    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        positionComment()
    }
    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        // The frozen snapshot stays fixed; cancel a region gesture if its source
        // window changes size so the selected coordinates can never drift.
        if overlay != nil { cancelAnnotation() } else { positionComment() }
    }
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        if popover === closingPopover {
            let finish = finishAfterPopoverClose
            popover.delegate = nil; closingPopover = nil; finishAfterPopoverClose = nil
            finish?()
        } else if popover === commentPopover {
            cancelAnnotation()
        }
    }
    func popoverDidShow(_ notification: Notification) {
        guard let content = commentPopover?.contentViewController?.view, let commentInput else { return }
        content.window?.title = "Add annotation"
        content.window?.makeKey(); content.window?.makeFirstResponder(commentInput)
    }
    func updateCommands() {
        onAnnotationStateChange?()
        if NSApp.keyWindow?.identifier?.rawValue == "NoodleScreenCapture" { return }
        guard Self.active === self || AnnotationCommandsState.shared.owner === self else { return }
        AnnotationCommandsState.shared.owner = Self.active
        AnnotationCommandsState.shared.enabled = canAnnotate
    }
    /// The exact boundary installed in AppKit, including weak-owner behavior.
    /// A nil result means the event must never reach the native preview.
    func eventMonitorHandler() -> (NSEvent) -> NSEvent? {
        { [weak self] event in
            guard let self else { return event }
            // Do not coalesce handle's nil: it tells AppKit the annotation
            // consumed this event. Forwarding it also dismisses Quick Look.
            return self.handle(event)
        }
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        // Consume the whole Escape press, including repeats that arrive after
        // the editor has disappeared. They must not close the underlying QL.
        if event.type == .keyUp, event.keyCode == 53 {
            let consumed = annotationEscapeDown
            annotationEscapeDown = false
            if consumed, conversationWindow == nil, item == nil, !hasPendingAnnotation, let monitor {
                NSEvent.removeMonitor(monitor); self.monitor = nil
            }
            return consumed ? nil : event
        }
        if event.type == .keyDown, event.keyCode == 53, annotationEscapeDown { return nil }
        guard let window = event.window, window === annotationWindow || window === overlay ||
                window === commentPopover?.contentViewController?.view.window ||
                window === closingPopover?.contentViewController?.view.window else { return event }
        if event.type == .keyUp { return event }
        if event.type != .keyDown {
            if window === panel, pending == nil, !busy {
                let point = window.convertPoint(toScreen: event.locationInWindow)
                lastPointerInPreview = NSPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
            }
            return event
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 53, pending != nil || busy || closingPopover != nil {
            annotationEscapeDown = true
            if closingPopover == nil { cancelAnnotation() }
            return nil
        }
        if window === panel, event.keyCode == 53 ||
            (flags == .command && event.charactersIgnoringModifiers?.lowercased() == "w") {
            previewWillStartClosing()
            return event
        }
        let bindings = KeyboardBindings.shared
        if commentPopover != nil, bindings.matches(.saveAnnotation, event: event) {
            if !event.isARepeat { saveComment() }; return nil
        }
        // The popover shares QL's responder owner with the chat. SwiftUI can
        // retain the attachment card's Space action across that window handoff.
        // Deliver text entry to NSTextView before it can reopen the attachment
        // (and dismiss its annotation), preserving selection and input methods.
        if event.keyCode == 49, flags.intersection([.command, .control]).isEmpty,
           let input = commentInput, input.window === window, window.firstResponder === input {
            input.keyDown(with: event)
            return nil
        }
        guard canAnnotate, !event.isARepeat else { return event }
        if bindings.matches(.annotateSelection, event: event) { annotate(); return nil }
        if bindings.matches(.annotateRegion, event: event) { startRegion(); return nil }
        return event
    }
    @objc func annotate() {
        guard canAnnotate, let source else { return }
        if source.mediaType.hasPrefix("image/") { startRegion(); return }
        captureSelection()
    }
    private func prepareAnnotation() {
        previewResponder = panel?.firstResponder
        if let panel {
            textAnchorInPreview = AnnotationPopoverAnchor.point(in: panel.frame,
                screenPointer: NSEvent.mouseLocation, lastPoint: lastPointerInPreview)
        }
        busy = true
    }
    private func captureSelection() {
        guard let source, let panel else { return }
        prepareAnnotation()
        let token = generation
        let board = NSPasteboard.general
        let oldCount = board.changeCount
        let oldItems = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        guard board.changeCount == oldCount else {
            busy = false
            showAnnotationError(CaptureError.clipboardChanged)
            return
        }
        let sent = NSApp.sendAction(NSSelectorFromString("copy:"), to: nil, from: self)
        operation = Task { @MainActor [weak self] in
            var copied: String?
            if sent {
                for _ in 0..<20 {
                    // Also accept synchronous copy providers without suspending.
                    if board.changeCount != oldCount {
                        // Accept the copy only for this still-focused session.
                        // Preserve non-text clipboard results too (for example,
                        // Quick Look copying a file when no text is selected).
                        if !Task.isCancelled, self?.generation == token, NSApp.keyWindow === panel {
                            let count = board.changeCount
                            let value = board.string(forType: .string)
                            let restored = oldItems.map { values in
                                let item = NSPasteboardItem()
                                for (type, data) in values { item.setData(data, forType: type) }
                                return item
                            }
                            if board.changeCount == count {
                                copied = value
                                board.clearContents()
                                if !restored.isEmpty { board.writeObjects(restored) }
                            }
                        }
                        break
                    }
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            guard let self, self.generation == token else { return }
            self.busy = false
            guard self.canAnnotate else { return }
            let quote = copied.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            self.pending = Pending(source: source, quote: quote)
            self.showComment(message: quote == nil ? "Whole attachment · no selected text" : nil)
        }
    }
    @objc func startRegion() {
        guard canAnnotate, let panel, let source else { return }
        // Capture only our process; never request access to other apps' windows.
        prepareAnnotation()
        let token = generation
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func isCurrent() -> Bool {
                self.generation == token && panel.isVisible && NSApp.keyWindow === panel &&
                    self.ownsPanel && panel.currentPreviewItem?.previewItemURL == self.currentURL
            }
            do {
                // QL has no public ready notification. Wait through its initial
                // crossfade and retry if it resizes while capture is in flight.
                let remaining = max(0, 0.8 - Date().timeIntervalSince(self.openedAt))
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                for _ in 0..<4 {
                    guard isCurrent() else {
                        if self.generation == token { self.busy = false }; return
                    }
                    let captureFrame = panel.frame
                    try await Task.sleep(for: .milliseconds(150))
                    guard isCurrent() else {
                        if self.generation == token { self.busy = false }; return
                    }
                    if panel.frame != captureFrame { continue }
                    let content = try await SCShareableContent.currentProcess
                    guard let window = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) else {
                        throw CaptureError.unavailable
                    }
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration()
                    let scale = min(panel.backingScaleFactor, 2)
                    config.width = max(1, Int(window.frame.width * scale))
                    config.height = max(1, Int(window.frame.height * scale))
                    config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                    config.includeChildWindows = false; config.captureResolution = .best
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard isCurrent() else {
                        if self.generation == token { self.busy = false }; return
                    }
                    if panel.frame != captureFrame { continue }
                    self.busy = false
                    self.pendingImage = NSImage(cgImage: image, size: captureFrame.size)
                    self.pending = Pending(source: source)
                    self.showRegion(image: self.pendingImage!, frame: captureFrame)
                    return
                }
                throw CaptureError.previewChanged
            } catch {
                guard self.generation == token else { return }
                self.busy = false
                if !Task.isCancelled { self.showAnnotationError(error) }
            }
        }
    }
    enum CaptureError: LocalizedError {
        case unavailable, previewChanged, clipboardChanged
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The preview could not be captured. Reopen the attachment and try again."
            case .previewChanged: return "The preview is still changing size. Let it finish, then try annotating the region again."
            case .clipboardChanged: return "The clipboard changed while preparing the selection. Try adding the annotation again."
            }
        }
    }
    func showAnnotationError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "Annotation couldn’t be completed"
        alert.informativeText = error.localizedDescription
        if let window = commentPopover?.contentViewController?.view.window ?? annotationWindow {
            alert.beginSheetModal(for: window) { _ in }
        }
    }
    @objc func saveComment() {
        guard let pending, let commentInput, let save else { return }
        let note = AttachmentAnnotation(source: pending.source, quote: pending.quote,
            comment: commentInput.string, region: pending.region, sourceMessageID: pending.sourceMessageID)
        guard note.isValid else { NSSound.beep(); return }
        do {
            try save(note, AnnotationContent.data(for: note, snapshot: pendingImage), pending.source)
            dismissAnnotation(returnFocus: true)
        } catch { showAnnotationError(error) }
    }
    @objc func cancelAnnotation() {
        trace("annotation cancelled")
        dismissAnnotation(returnFocus: true)
    }
    func dismissAnnotation(returnFocus: Bool = false) {
        guard !isDismissing else { return }
        if returnFocus {
            guard closingPopover == nil,
                  pending != nil || busy || commentPopover != nil || overlay != nil || conversationCanvas != nil else { return }
        }
        isDismissing = true
        defer { isDismissing = false }
        generation = UUID(); operation?.cancel(); operation = nil
        let token = generation
        let responder = previewResponder
        let expectedURL = currentURL
        let conversation = conversationWindow
        let restore: @MainActor @Sendable () -> Void = { [weak self] in
            if let conversation, let self, self.generation == token, NSApp.isActive,
               conversation.isVisible, !self.hasPendingAnnotation, conversation.attachedSheet == nil {
                conversation.makeKey()
                if let responder { conversation.makeFirstResponder(responder) }
                return
            }
            guard let self, self.generation == token, Self.active === self,
                  NSApp.isActive, let panel = self.panel, panel.isVisible,
                  let expectedURL, self.currentURL == expectedURL,
                  self.pending == nil, !self.busy, self.commentPopover == nil,
                  self.closingPopover == nil, self.overlay == nil,
                  self.ownsPanel || panel.currentController == nil else { return }
            if !self.ownsPanel { panel.updateController() }
            guard self.ownsPanel else { return }
            if panel.dataSource as? AttachmentPreviewController !== self {
                self.configurePreviewPanel(panel)
                panel.reloadData()
            }
            self.trace("annotation focus return")
            panel.makeKey()
            if let responder { panel.makeFirstResponder(responder) }
            self.updateCommands()
        }
        // Explicit preview close/navigation cancels any pending focus return.
        closingPopover?.delegate = nil
        closingPopover = nil; finishAfterPopoverClose = nil
        let popover = commentPopover
        let children = [commentPanel, overlay].compactMap { $0 }
        commentPopover = nil
        commentInput = nil; pending = nil; pendingImage = nil
        textAnchorInPreview = nil; previewResponder = nil; busy = false
        let finish = { [weak self] in
            guard let self, self.generation == token else { return }
            // Retain the anchor and overlay until the popover has actually
            // closed, so removing a parent cannot interrupt its animation.
            for child in children {
                child.delegate = nil; child.parent?.removeChildWindow(child); child.orderOut(nil)
            }
            self.commentPanel = nil; self.overlay = nil
            if let canvas = self.conversationCanvas {
                canvas.window?.invalidateCursorRects(for: canvas)
                canvas.removeFromSuperview(); self.conversationCanvas = nil
                if NSCursor.current == .crosshair { NSCursor.arrow.set() }
            }
            if conversation != nil {
                self.conversationWindow = nil; self.save = nil
                Self.conversationEditors.remove(self)
                // Keep the monitor through Escape's key-up so a single press
                // cannot also dismiss the underlying conversation.
                if !self.annotationEscapeDown, let monitor = self.monitor {
                    NSEvent.removeMonitor(monitor); self.monitor = nil
                }
            }
            if returnFocus { DispatchQueue.main.async(execute: restore) }
            self.updateCommands()
        }
        if let popover, popover.isShown, returnFocus {
            closingPopover = popover
            finishAfterPopoverClose = finish
            popover.close()
        } else {
            popover?.delegate = nil
            popover?.close()
            finish()
        }
        updateCommands()
    }

    private func trace(_ event: String) {
        // Deliberately omit filenames, selected text and comments.
        lifecycleLog.info("\(event, privacy: .public); visible=\(self.panel?.isVisible == true) key=\(self.panel?.isKeyWindow == true) item=\(self.item != nil) annotation=\(self.pending != nil || self.closingPopover != nil)")
    }
}

/// Native close notifications are observations, not requests to close again.
/// Kept independent of QL's rendering so real NSWindow lifecycle notifications
/// can be checked offscreen without substituting or subclassing QLPreviewPanel.
@MainActor final class PreviewWindowSession: NSObject {
    private weak var window: NSWindow?
    private var didEnd: (() -> Void)?

    init(window: NSWindow, didEnd: @escaping () -> Void) {
        self.window = window; self.didEnd = didEnd
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: window)
    }

    /// Only an explicit app request may ask the native window to disappear.
    func close() {
        let window = window
        finish()
        window?.orderOut(nil)
    }

    func invalidate() {
        NotificationCenter.default.removeObserver(self)
        window = nil; didEnd = nil
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        finish()
    }

    private func finish() {
        let completion = didEnd
        invalidate()
        completion?()
    }
}
