import AppKit
import ScreenCaptureKit
import SwiftUI
import NoodleCore

private struct ConversationAnnotationsKey: EnvironmentKey {
    static let defaultValue: ConversationAnnotationController? = nil
}

extension EnvironmentValues {
    var conversationAnnotations: ConversationAnnotationController? {
        get { self[ConversationAnnotationsKey.self] }
        set { self[ConversationAnnotationsKey.self] = newValue }
    }
}

struct ConversationAnnotationHost: NSViewRepresentable {
    let controller: ConversationAnnotationController
    let conversationID: UUID
    let title: String
    let save: (AttachmentAnnotation, Data, ConversationAttachment, Data) throws -> Void

    func makeNSView(context: Context) -> Host { Host(controller: controller) }
    func updateNSView(_ view: Host, context: Context) {
        view.setController(controller)
        controller.configure(conversationID: conversationID, title: title, save: save)
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.setController(nil) }

    final class Host: NSView {
        private(set) weak var controller: ConversationAnnotationController?
        private var attachmentGeneration = 0

        init(controller: ConversationAnnotationController) {
            self.controller = controller
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        func setController(_ controller: ConversationAnnotationController?) {
            guard self.controller !== controller else { return }
            self.controller?.attach(to: nil)
            self.controller = controller
            scheduleAttachment()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            attachmentGeneration += 1
            controller?.attach(to: nil)
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleAttachment()
        }

        private func scheduleAttachment() {
            attachmentGeneration += 1
            let generation = attachmentGeneration
            // AppKit can ask SwiftUI to update during NSWindow.dealloc, before
            // view.window is cleared. Never weak-register that window from an
            // update callback; resolve it after the mount has settled instead.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.attachmentGeneration == generation else { return }
                self.controller?.attach(to: self.window)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A passive geometry marker leaves SwiftUI's native text selection and Markdown
/// rendering intact. Mouse-down identifies the message even when quotes repeat.
struct ConversationAnnotationText: NSViewRepresentable {
    @Environment(\.conversationAnnotations) private var controller
    let message: ChatMessage
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {
        if view.controller !== controller {
            view.controller?.markers.remove(view)
            view.controller = controller
            controller?.markers.add(view)
        }
        view.message = message
    }
    static func dismantleNSView(_ view: Marker, coordinator: ()) { view.controller?.markers.remove(view) }

    final class Marker: NSView {
        weak var controller: ConversationAnnotationController?
        var message: ChatMessage?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor final class ConversationAnnotationController: NSObject, PreviewAnnotationTarget {
    let editor = AttachmentPreviewController()
    let markers = NSHashTable<ConversationAnnotationText.Marker>.weakObjects()
    private(set) weak var window: NSWindow?
    private weak var selectedText: ConversationAnnotationText.Marker?
    private var conversationID: UUID?
    private var title = "Conversation"
    private var save: ((AttachmentAnnotation, Data, ConversationAttachment, Data) throws -> Void)?
    private var monitor: Any?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var busy = false

    override init() {
        super.init()
        editor.onAnnotationStateChange = { [weak self] in self?.updateCommands() }
    }

    func configure(conversationID: UUID, title: String,
                   save: @escaping (AttachmentAnnotation, Data, ConversationAttachment, Data) throws -> Void) {
        if self.conversationID != conversationID { cancel(); selectedText = nil }
        self.conversationID = conversationID; self.title = title; self.save = save
        updateCommands()
    }

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        cancel()
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        self.window = window
        selectedText = nil
        if window != nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.willCloseNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
            }
        }
        updateCommands()
    }

    var canAnnotate: Bool {
        window != nil && window?.isVisible == true && NSApp.keyWindow === window &&
            conversationID != nil && save != nil && !busy && !editor.hasPendingAnnotation &&
            NSApp.modalWindow == nil && window?.attachedSheet == nil
    }

    private func updateCommands() {
        let state = AnnotationCommandsState.shared
        if canAnnotate {
            state.conversationOwner = self; state.conversationEnabled = true
        } else if state.conversationOwner === self {
            state.conversationEnabled = false
        }
    }

    @objc private func windowChanged(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            if notification.name == NSWindow.willCloseNotification { attach(to: nil); return }
            if notification.name == NSWindow.didResizeNotification || notification.name == NSWindow.didMoveNotification {
                if busy || editor.overlay != nil || editor.conversationCanvas != nil { cancel() }
                else { editor.positionComment() }
            }
        }
        // AppKit updates keyWindow around these notifications. Read the settled
        // window so opening a preview or a sheet cannot leave chat commands live.
        DispatchQueue.main.async { [weak self] in self?.updateCommands() }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        if event.type == .leftMouseDown {
            selectedText = markers.allObjects.first {
                $0.window === window && !$0.isHiddenOrHasHiddenAncestor &&
                    $0.bounds.intersection($0.visibleRect).contains($0.convert(event.locationInWindow, from: nil))
            }
            return event
        }
        if event.keyCode == 53, busy { cancel(); return nil }
        guard canAnnotate else { return event }
        let bindings = KeyboardBindings.shared
        if bindings.matches(.annotateSelection, event: event) {
            if !event.isARepeat { annotate() }
            return nil
        }
        if bindings.matches(.annotateRegion, event: event) {
            if !event.isARepeat { startRegion() }
            return nil
        }
        return event
    }

    func annotate() {
        guard canAnnotate, let window, let conversationID, let save,
              let message = selectedText?.message, message.conversationID == conversationID,
              (window.firstResponder as? NSTextView)?.isEditable != true else { NSSound.beep(); return }
        busy = true; updateCommands()
        let token = generation
        let board = NSPasteboard.general
        let oldCount = board.changeCount
        let oldItems = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        guard board.changeCount == oldCount else { busy = false; updateCommands(); return }
        let sent = NSApp.sendAction(NSSelectorFromString("copy:"), to: nil, from: self)
        operation = Task { @MainActor [weak self] in
            var quote: String?
            if sent {
                for _ in 0..<20 {
                    if board.changeCount != oldCount {
                        let count = board.changeCount
                        let value = board.string(forType: .string)
                        if board.changeCount == count {
                            board.clearContents()
                            let restored = oldItems.map { values in
                                let item = NSPasteboardItem()
                                for (type, data) in values { item.setData(data, forType: type) }
                                return item
                            }
                            if !restored.isEmpty { board.writeObjects(restored) }
                            quote = value
                        }
                        break
                    }
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            guard let self, self.generation == token else { return }
            self.busy = false
            defer { self.updateCommands() }
            guard !Task.isCancelled, self.canAnnotate, let quote,
                  !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  String(MessageMarkdownCache.shared.render(message).characters).contains(quote) else { NSSound.beep(); return }
            let safeTitle = String(self.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(100))
            let filename = "Message — \(safeTitle).txt"
            let raw = Data("Conversation: \(conversationID.uuidString)\nMessage: \(message.id.uuidString)\n\n\(message.body)".utf8)
            let source = ConversationAttachment(conversationID: conversationID, originalFilename: filename,
                storedFilename: filename, mediaType: "text/plain", byteCount: Int64(raw.count))
            self.editor.annotateConversation(in: window, source: source, quote: quote, messageID: message.id) { note, content, source in
                try save(note, content, source, raw)
            }
        }
    }

    func startRegion() {
        guard canAnnotate, let window, let conversationID, let save else { return }
        busy = true; updateCommands()
        let token = generation
        let frame = window.frame
        let title = self.title
        operation = Task { @MainActor [weak self] in
            do {
                let content = try await SCShareableContent.currentProcess
                guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    throw AttachmentPreviewController.CaptureError.unavailable
                }
                let config = SCStreamConfiguration()
                config.width = max(1, Int(target.frame.width * window.backingScaleFactor))
                config.height = max(1, Int(target.frame.height * window.backingScaleFactor))
                config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.scalesToFit = true
                config.includeChildWindows = false; config.captureResolution = .best
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
                guard let self, self.generation == token else { return }
                self.busy = false
                defer { self.updateCommands() }
                guard !Task.isCancelled, self.canAnnotate, window.frame == frame else { return }
                let raw = try CaptureAttachment.png(image)
                let safeTitle = String(title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(100))
                let filename = "Conversation — \(safeTitle).png"
                let source = ConversationAttachment(conversationID: conversationID, originalFilename: filename,
                    storedFilename: filename, mediaType: "image/png", byteCount: Int64(raw.count))
                self.editor.annotateConversation(in: window, source: source, quote: nil,
                    snapshot: NSImage(cgImage: image, size: frame.size)) { note, content, source in
                    try save(note, content, source, raw)
                }
            } catch {
                guard let self, self.generation == token else { return }
                self.busy = false; self.updateCommands()
                if !Task.isCancelled, self.canAnnotate {
                    let alert = NSAlert(); alert.messageText = "Conversation couldn’t be captured"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window) { _ in }
                }
            }
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil; busy = false
        editor.close()
        updateCommands()
    }
}
