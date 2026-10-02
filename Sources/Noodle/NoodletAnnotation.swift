import AppKit
import AppletBridge
import NoodleCore
import NoodleRuntime

/// Annotating a noodlet open in Noodle Applet, in place. Applet passes on the person's Annotate
/// Region shortcut in a noodlet Noodle opened from a conversation; Noodle takes a picture of it
/// and marks it up into that conversation. A noodlet opened in Applet itself has none to go to.
@MainActor final class NoodletAnnotations {
    struct Capture {
        let conversationID: UUID
        let title: String
        let raw: Data
        /// Where the noodlet's page is on screen.
        let frame: CGRect
    }

    /// Posted by Applet with the session's id; anything may post it, so only sessions opened
    /// here are annotated.
    let notification: String
    var present: ((Capture) -> Void)?
    private let applets: AppletController
    /// The conversation each session was last opened from.
    private var conversations: [UUID: UUID] = [:]
    private var observer: Any?
    private var capturing = false

    init(applets: AppletController, notification: String = "\(Bundle.main.bundleIdentifier ?? "Noodle").annotate-noodlet",
         present: ((Capture) -> Void)? = nil) {
        self.applets = applets
        self.notification = notification
        self.present = present
    }

    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }

    func listen() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: .init(notification), object: nil, queue: .main) { [weak self] note in
                guard let session = (note.object as? String).flatMap(UUID.init(uuidString:)) else { return }
                MainActor.assumeIsolated { Task { await self?.annotate(session: session) } }
            }
    }

    /// Opens a noodlet for the person, passing on `shortcut`, the Annotate Region one, if set.
    func open(_ url: URL, from conversationID: UUID, shortcut: KeyBinding?) async throws {
        let annotation = shortcut.map {
            AppletAnnotation(notification: notification, key: $0.key, modifiers: $0.modifiers.rawValue)
        }
        let response = try await applets.openNoodlet(url, annotation: annotation)
        if annotation != nil, let session = response.sessionID { conversations[session] = conversationID }
    }

    func annotate(session: UUID) async {
        guard !capturing, let conversationID = conversations[session] else { return }
        capturing = true
        defer { capturing = false }
        do {
            let shot = try await applets.companion(AppletRequest(.screenshot, sessionID: session))
            // Only a noodlet on screen can be marked where it is.
            guard let artifact = shot.artifactID, let frame = shot.screenFrame else { return NSSound.beep() }
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
            present?(Capture(conversationID: conversationID, title: shot.text ?? "Noodlet", raw: raw, frame: frame))
        } catch {
            NSSound.beep()
        }
    }
}

/// The picture laid exactly over the noodlet's window, so it seems to stop where it is, and marked
/// with the conversation's annotation editor. The app that was in front gets the keyboard back.
@MainActor final class NoodletAnnotationOverlay {
    private(set) var window: NSWindow?
    private(set) var editor: AttachmentPreviewController?
    private var previous: NSRunningApplication?

    func present(_ capture: NoodletAnnotations.Capture,
                 save: @escaping (AttachmentAnnotation, Data, ConversationAttachment, Data) throws -> Void) {
        guard window == nil, let image = NSImage(data: capture.raw) else { return }
        image.size = capture.frame.size
        let window = OverlayWindow(contentRect: capture.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = false; window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSView(frame: NSRect(origin: .zero, size: capture.frame.size))
        previous = NSWorkspace.shared.frontmostApplication
        // Activation brings only the key and main windows forward, so the rest of Noodle stays behind.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let safeTitle = String(capture.title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-").prefix(100))
        let filename = "Noodlet — \(safeTitle).png"
        let source = ConversationAttachment(conversationID: capture.conversationID, originalFilename: filename,
            storedFilename: filename, mediaType: "image/png", byteCount: Int64(capture.raw.count))
        let editor = AttachmentPreviewController()
        self.window = window; self.editor = editor
        editor.annotateConversation(in: window, source: source, quote: nil, snapshot: image) { note, content, source in
            try save(note, content, source, capture.raw)
        }
        // Only now, as starting closes any earlier annotation and reports that too.
        editor.onAnnotationStateChange = { [weak self] in self?.finishIfDone() }
    }

    private func finishIfDone() {
        guard let editor, let window, !editor.isConversationAnnotation else { return }
        self.editor = nil; self.window = nil
        window.orderOut(nil)
        if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous?.activate() }
        previous = nil
    }

    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}
