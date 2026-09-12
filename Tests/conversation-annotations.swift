import AppKit
import SwiftUI
import ScreenCaptureKit
import NoodleCore

@MainActor private struct TranscriptFixture: View {
    let controller: ConversationAnnotationController
    let preview: AttachmentPreviewController
    let messages: [ChatMessage]
    let save: (AttachmentAnnotation, Data, ConversationAttachment, Data) throws -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 35) {
            ForEach(messages) { message in
                Text(MessageMarkdownCache.shared.render(message))
                    .font(.system(size: 18)).textSelection(.enabled)
                    .background(ConversationAnnotationText(message: message))
            }
            TextField("Message", text: .constant("Composer text"))
            Spacer()
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.conversationAnnotations, controller)
        .background(ConversationAnnotationHost(controller: controller, conversationID: messages[0].conversationID,
            title: "Annotation test", save: save).frame(width: 0, height: 0))
        .background(AttachmentPreviewHost(controller: preview))
    }
}

@MainActor private final class ConversationAnnotationFixture: NSObject, NSApplicationDelegate {
    let controller = ConversationAnnotationController()
    let preview = AttachmentPreviewController()
    var window: NSWindow!
    var repository: WorkspaceRepository!
    var root: URL!
    var saved: [ConversationAnnotationContent.Saved] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await run()
                print("PASS: conversation annotations — native selected text, repeated quotes, clipboard, own-window capture, save/cancel, focus, navigation, preview routing and custom shortcuts")
                controller.attach(to: nil); preview.close(); window.close()
                try? FileManager.default.removeItem(at: root)
                NSApp.terminate(nil)
            } catch { fixtureFailure(error.localizedDescription) }
        }
    }

    func pause() async throws { try await Task.sleep(for: .milliseconds(150)) }
    func until(_ message: String, _ test: () -> Bool) async throws {
        for _ in 0..<100 { if test() { return }; try await Task.sleep(for: .milliseconds(50)) }
        fixtureFailure(message)
    }
    func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in target: NSWindow) async throws {
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!, atStart: false)
        }
        try await pause()
    }
    func click(_ point: NSPoint, count: Int = 1) async throws {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!, atStart: false)
        }
        try await pause()
    }
    func chooseRegion() async throws {
        try await until("Window capture did not mount its selection canvas") { self.controller.editor.conversationCanvas?.window === self.window }
        require(controller.editor.overlay == nil && window.isKeyWindow, "Conversation selection must stay inside the original window")
        let canvas = controller.editor.conversationCanvas!
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(NSPoint(x: canvas.bounds.width * x, y: canvas.bounds.height * y), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, 0.2, 0.3))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, 0.65, 0.7))
        canvas.mouseUp(with: mouse(.leftMouseUp, 0.65, 0.7))
        try await until("Region comment must receive focus") { self.controller.editor.commentInput?.window?.isKeyWindow == true }
    }

    func captureSelectionEvidence() async throws {
        try await until("Selection must mount before capturing evidence") { self.controller.editor.conversationCanvas?.window === self.window }
        let snapshot = controller.editor.pendingImage!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let pixels = NSBitmapImageRep(cgImage: snapshot)
        let corner = pixels.colorAt(x: pixels.pixelsWide * 9 / 10, y: pixels.pixelsHigh * 9 / 10)!.usingColorSpace(.deviceRGB)!
        require(corner.redComponent + corner.greenComponent + corner.blueComponent > 0.05,
            "Frozen snapshot must fill the captured frame without black padding")
        let content = try await SCShareableContent.currentProcess
        let target = content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }!
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width * 2); config.height = Int(target.frame.height * 2)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.captureResolution = .best; config.scalesToFit = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-selection.png")
        try CaptureAttachment.png(image).write(to: output)
        print("SELECTION_IMAGE: \(output.path)")
    }

    func run() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-annotation-ui-\(UUID())")
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Reviewer")
        let messages = (0..<2).map { _ in ChatMessage(conversationID: bot.conversation.id, author: .agent(bot.agent.id),
            body: "Quoted **detail** appears twice. 🪄", delivery: .delivered) }
        for message in messages { try repository.append(message) }
        window = NSWindow(contentRect: NSRect(x: 150, y: 180, width: 720, height: 470),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Conversation annotation test"
        window.contentView = NSHostingView(rootView: TranscriptFixture(controller: controller, preview: preview, messages: messages) { [unowned self] note, content, source, raw in
            saved.append(try ConversationAnnotationContent.save(note, content: content, source: source, sourceData: raw, repository: repository))
        })
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await until("Conversation must mount and receive focus") { self.controller.canAnnotate && self.controller.markers.count == 2 }
        // A shortcut without a selected message must not annotate the composer.
        try await key("a", code: 0, flags: [.command, .shift], in: window)
        require(!controller.editor.hasPendingAnnotation)
        let marker = controller.markers.allObjects.first { $0.message?.id == messages[1].id }!
        let point = marker.convert(NSPoint(x: 12, y: marker.bounds.midY), to: nil)
        try await click(point, count: 2)
        let board = NSPasteboard.general
        func clipboard() -> [[NSPasteboard.PasteboardType: Data]] {
            (board.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
            }
        }
        let previousClipboard = clipboard()
        try await key("a", code: 0, flags: [.command, .shift], in: window)
        try await until("Native selected text must open the annotation editor") { self.controller.editor.commentInput?.window?.isKeyWindow == true }
        require(controller.editor.pending?.quote == "Quoted", "Copy must preserve the exact native selection: \(String(describing: controller.editor.pending?.quote))")
        require(controller.editor.pending?.sourceMessageID == messages[1].id, "Repeated quotes must reference the selected message: actual=\(String(describing: controller.editor.pending?.sourceMessageID)), expected=\(messages[1].id)")
        require(clipboard() == previousClipboard, "Annotation must restore all clipboard formats")
        let beforeSave = try repository.loadAttachments(conversationID: bot.conversation.id)
        require(beforeSave.isEmpty, "Opening an annotation must not persist a source")
        controller.editor.commentInput!.string = "Please explain this"
        try await key("\r", code: 36, flags: .command, in: controller.editor.commentInput!.window!)
        try await until("Save must return focus to the conversation") { self.window.isKeyWindow && !self.controller.editor.hasPendingAnnotation }
        require(saved.count == 1 && saved[0].attachment.annotation?.quote == "Quoted")
        require(saved[0].attachment.annotation?.sourceMessageID == messages[1].id)

        let originalFrame = window.frame
        try await key("r", code: 15, flags: [.command, .shift], in: window)
        try await captureSelectionEvidence()
        require(window.frame == originalFrame && window.isKeyWindow)
        try await chooseRegion()
        require(controller.editor.pendingImage != nil && controller.editor.pending?.region?.isValid == true)
        let editor = controller.editor
        try await key("\u{1b}", code: 53, in: editor.commentInput!.window!)
        try await until("Escape must cancel only the annotation") { self.window.isKeyWindow && !editor.hasPendingAnnotation }
        require(saved.count == 1 && window.isVisible)
        let afterCancel = try repository.loadAttachments(conversationID: bot.conversation.id)
        require(afterCancel.count == 2, "Cancelled capture must not leave files")

        // Cancelling before a rectangle is drawn never changes the key window.
        // Menu availability must recover without relying on a focus notification.
        try await key("r", code: 15, flags: [.command, .shift], in: window)
        try await until("Inline selection must open") { editor.conversationCanvas != nil }
        try await key("\u{1b}", code: 53, in: window)
        try await until("Inline Escape must restore menu commands") {
            !editor.hasPendingAnnotation && AnnotationCommandsState.shared.conversationEnabled
        }
        require(window.isKeyWindow && saved.count == 1)

        let binding = KeyboardBindings.shared.binding(for: .annotateRegion)
        defer { try? KeyboardBindings.shared.set(binding, for: .annotateRegion) }
        try KeyboardBindings.shared.set(KeyBinding("r", modifiers: [.command, .option]), for: .annotateRegion)
        try await key("r", code: 15, flags: [.command, .shift], in: window)
        require(!editor.hasPendingAnnotation, "Old shortcut must stop working after rebinding")
        try await key("r", code: 15, flags: [.command, .option], in: window)
        try await chooseRegion()
        editor.commentInput!.string = "Move this detail"
        try await key("\r", code: 36, flags: .command, in: editor.commentInput!.window!)
        try await until("Region save must return focus") { self.window.isKeyWindow && !editor.hasPendingAnnotation }
        require(saved.count == 2 && saved[1].attachment.mediaType == "image/png")
        require(saved[1].attachment.annotation?.comment == "Move this detail")
        let png = try Data(contentsOf: repository.attachmentFileURL(saved[1].attachment))
        require(NSBitmapImageRep(data: png) != nil)

        preview.show(saved[0].source, url: repository.attachmentFileURL(saved[0].source)) { _, _, _ in fixtureFailure("Preview check should cancel") }
        try await until("Attachment preview must own its shortcuts") { self.preview.canAnnotate && !self.controller.canAnnotate }
        try await pause()
        _ = NSApp.sendAction(NSSelectorFromString("selectAll:"), to: nil, from: nil)
        try await key("a", code: 0, flags: [.command, .shift], in: preview.panel!)
        try await until("Preview annotation must open its own editor") { self.preview.commentInput?.window?.isKeyWindow == true }
        require(!editor.hasPendingAnnotation)
        try await key("\u{1b}", code: 53, in: preview.commentInput!.window!)
        try await until("Cancel must keep attachment preview open") { self.preview.canAnnotate }
        preview.close(); window.makeKeyAndOrderFront(nil)
        try await until("Conversation commands must resume after preview closes") { self.controller.canAnnotate }
        try await key("r", code: 15, flags: [.command, .option], in: window)
        try await chooseRegion()
        controller.configure(conversationID: UUID(), title: "Different conversation", save: { _, _, _, _ in fixtureFailure("Navigation must cancel") })
        require(!editor.hasPendingAnnotation && editor.overlay == nil && editor.conversationCanvas == nil && editor.commentPopover == nil)
        require(saved.count == 2)
    }
}

@main private struct ConversationAnnotationMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu()
        appItem.submenu!.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        let editItem = NSMenuItem(); editItem.submenu = NSMenu(title: "Edit")
        for (title, key, action) in [("Copy", "c", "copy:"), ("Select All", "a", "selectAll:")] {
            editItem.submenu!.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        menu.addItem(editItem); app.mainMenu = menu
        let delegate = ConversationAnnotationFixture(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
