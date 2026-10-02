import AppKit
import AppletBridge
import NoodleCore
import NoodleRuntime

/// Annotating a noodlet open in Noodle Applet, in place. Applet passes on the person's Annotate
/// Region and Add Annotation shortcuts in a noodlet Noodle opened from a conversation; Noodle marks
/// up a picture of it, or quotes the text selected in it, into that conversation. A noodlet opened
/// in Applet itself has none to go to.
@MainActor final class NoodletAnnotations {
    struct Capture {
        let conversationID: UUID
        let title: String
        /// The picture, or for a quote the page's text.
        let raw: Data
        let quote: String?
        /// Where the noodlet's page and its window are on screen.
        let frame: CGRect
        let windowFrame: CGRect
    }

    /// Posted by Applet with the session's id, with `.region` or `.selection` added; anything may
    /// post it, so only sessions opened here are annotated.
    let notification: String
    var present: ((Capture) -> Void)?
    private let applets: AppletController
    /// The conversation each session was last opened from.
    private var conversations: [UUID: UUID] = [:]
    private var observers: [Any] = []
    private var capturing = false

    init(applets: AppletController, notification: String = "\(Bundle.main.bundleIdentifier ?? "Noodle").annotate-noodlet",
         present: ((Capture) -> Void)? = nil) {
        self.applets = applets
        self.notification = notification
        self.present = present
    }

    deinit { observers.forEach(DistributedNotificationCenter.default().removeObserver) }

    func listen() {
        guard observers.isEmpty else { return }
        observers = [false, true].map { selection in
            DistributedNotificationCenter.default().addObserver(
                forName: .init("\(notification).\(selection ? "selection" : "region")"), object: nil, queue: .main
            ) { [weak self] note in
                guard let session = (note.object as? String).flatMap(UUID.init(uuidString:)) else { return }
                MainActor.assumeIsolated { Task { await self?.annotate(session: session, selection: selection) } }
            }
        }
    }

    /// Opens a noodlet for the person, passing on the Annotate Region and Add Annotation shortcuts that are set.
    func open(_ url: URL, from conversationID: UUID, region: KeyBinding?, selection: KeyBinding?) async throws {
        func shortcut(_ binding: KeyBinding?) -> AppletAnnotation.Shortcut? {
            binding.map { .init(key: $0.key, modifiers: $0.modifiers.rawValue) }
        }
        let annotation = region == nil && selection == nil ? nil : AppletAnnotation(
            application: Bundle.main.bundleIdentifier ?? "", notification: notification,
            region: shortcut(region), selection: shortcut(selection))
        let response = try await applets.openNoodlet(url, annotation: annotation)
        if annotation != nil, let session = response.sessionID { conversations[session] = conversationID }
    }

    func annotate(session: UUID, selection: Bool) async {
        guard !capturing, let conversationID = conversations[session] else { return }
        capturing = true
        defer { capturing = false }
        do {
            let capture = try await selection ? quote(session) : picture(session)
            // Only a noodlet on screen can be annotated where it is.
            guard let capture, let frame = capture.response.screenFrame, let windowFrame = capture.response.windowFrame
            else { return NSSound.beep() }
            present?(Capture(conversationID: conversationID, title: capture.response.title ?? "Noodlet", raw: capture.raw,
                             quote: capture.quote, frame: frame, windowFrame: windowFrame))
        } catch {
            NSSound.beep()
        }
    }

    private func picture(_ session: UUID) async throws -> (response: AppletResponse, raw: Data, quote: String?)? {
        let shot = try await applets.companion(AppletRequest(.screenshot, sessionID: session))
        guard let artifact = shot.artifactID else { return nil }
        var raw = Data()
        while true {
            var piece = AppletRequest(.artifact)
            piece.artifactID = artifact
            piece.offset = raw.count
            let read = try await applets.companion(piece)
            guard let data = read.data, !data.isEmpty || read.done == true else {
                throw AppletError("The noodlet's picture did not arrive.")
            }
            raw.append(data)
            if read.done == true { break }
        }
        return (shot, raw, nil)
    }

    /// The text selected in the page, and as its source all the page's text, as a message is for a quote from it.
    private func quote(_ session: UUID) async throws -> (response: AppletResponse, raw: Data, quote: String?)? {
        struct Page: Decodable { let selection: String; let text: String }
        var read = AppletRequest(.eval, sessionID: session)
        read.text = "return { selection: String(getSelection() ?? ''), text: (document.body?.innerText ?? '').slice(0, 200000) };"
        let response = try await applets.companion(read)
        guard let page = try? JSONDecoder().decode(Page.self, from: Data((response.value ?? "").utf8)),
              !page.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (response, Data("\(response.title ?? "Noodlet")\n\n\(page.text)".utf8), page.selection)
    }
}

/// The noodlet's picture laid exactly over its page, so it seems to stop where it is, and marked
/// with the conversation's annotation editor; a quote goes straight to its comment. The rest of
/// its window is shielded, so it cannot be moved from under the picture. The app that was in
/// front gets the keyboard back.
@MainActor final class NoodletAnnotationOverlay {
    private(set) var window: NSWindow?
    private(set) var editor: AttachmentPreviewController?
    private var previous: NSRunningApplication?

    func present(_ capture: NoodletAnnotations.Capture,
                 save: @escaping (AttachmentAnnotation, Data, ConversationAttachment, Data) throws -> Void) {
        guard window == nil else { return }
        let image = capture.quote == nil ? NSImage(data: capture.raw) : nil
        guard capture.quote != nil || image != nil else { return }
        image?.size = capture.frame.size
        let window = OverlayWindow(contentRect: capture.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = false; window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSView(frame: NSRect(origin: .zero, size: capture.frame.size))
        // All but invisible, as clicks go through what is fully clear.
        let shield = NSWindow(contentRect: capture.windowFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        shield.isReleasedWhenClosed = false; shield.isOpaque = false; shield.hasShadow = false
        shield.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        window.addChildWindow(shield, ordered: .below)
        previous = NSWorkspace.shared.frontmostApplication
        // Activation brings only the key and main windows forward, so the rest of Noodle stays behind.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let safeTitle = String(capture.title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-").prefix(100))
        let filename = "Noodlet — \(safeTitle).\(capture.quote == nil ? "png" : "txt")"
        let source = ConversationAttachment(conversationID: capture.conversationID, originalFilename: filename,
            storedFilename: filename, mediaType: capture.quote == nil ? "image/png" : "text/plain",
            byteCount: Int64(capture.raw.count))
        let editor = AttachmentPreviewController()
        self.window = window; self.editor = editor
        editor.annotateConversation(in: window, source: source, quote: capture.quote, snapshot: image) { note, content, source in
            try save(note, content, source, capture.raw)
        }
        // Only now, as starting closes any earlier annotation and reports that too.
        editor.onAnnotationStateChange = { [weak self] in self?.finishIfDone() }
    }

    private func finishIfDone() {
        guard let editor, let window, !editor.isConversationAnnotation else { return }
        self.editor = nil; self.window = nil
        for child in window.childWindows ?? [] { window.removeChildWindow(child); child.orderOut(nil) }
        window.orderOut(nil)
        if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous?.activate() }
        previous = nil
    }

    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}
