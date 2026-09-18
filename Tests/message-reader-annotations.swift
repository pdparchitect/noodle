import AppKit
import SwiftUI
import Observation
import NoodleCore

// The reader uses the same persistence entry point as the app. Keep the native
// fixture independent of harness startup and the user's workspace.
@MainActor @Observable final class NoodleStore {
    let repository: WorkspaceRepository
    let conversations: [BotConversation]
    var saved: [ConversationAnnotationContent.Saved] = []
    init(repository: WorkspaceRepository, conversation: BotConversation) {
        self.repository = repository; conversations = [conversation]
    }
    func title(for conversation: BotConversation) -> String { "Reader annotation test" }
    func saveConversationAnnotation(_ note: AttachmentAnnotation, content: Data, source: ConversationAttachment, sourceData: Data) throws {
        saved.append(try ConversationAnnotationContent.save(note, content: content, source: source,
            sourceData: sourceData, repository: repository))
    }
}

@MainActor @Observable private final class ReaderState { var showing = false }

private struct ReaderOpenAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {}
    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor private struct ReaderFixtureView: View {
    @Bindable var state: ReaderState
    let controller: ConversationAnnotationController
    let store: NoodleStore
    let message: ChatMessage
    @FocusState private var composerFocused: Bool
    var body: some View {
        VStack(spacing: 30) {
            Button("Read more") { state.showing = true }
                .background(ReaderOpenAnchor())
                .popover(isPresented: $state.showing, arrowEdge: .bottom) {
                    MessageTextReader(message: message, close: { state.showing = false })
                }
            TextField("Message", text: .constant("Unsent draft")).focused($composerFocused)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(store)
        .environment(\.conversationAnnotations, controller)
        .background(ConversationAnnotationHost(controller: controller, conversationID: message.conversationID,
            title: "Reader annotation test", save: store.saveConversationAnnotation,
            focusComposer: { composerFocused = true }).frame(width: 0, height: 0))
    }
}

@MainActor private final class ReaderAnnotationFixture: NSObject, NSApplicationDelegate {
    let parent = ConversationAnnotationController()
    let state = ReaderState()
    var window: NSWindow!
    var root: URL!
    var store: NoodleStore!
    var reader: NSWindow!
    var annotations: ConversationAnnotationController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await run()
                print("PASS: reader annotations — selected text, saved message references, Cmd+Shift+R, region save/cancel, reader lifetime across saves")
                parent.attach(to: nil); window.close()
                try? FileManager.default.removeItem(at: root)
                NSApp.terminate(nil)
            } catch { fixtureFailure(error.localizedDescription) }
        }
    }

    func until(_ message: String, _ test: () -> Bool) async throws {
        for _ in 0..<120 { if test() { return }; try await Task.sleep(for: .milliseconds(50)) }
        print("Failure state: active=\(NSApp.isActive), showing=\(state.showing), readerVisible=\(reader?.isVisible == true), readerKey=\(reader?.isKeyWindow == true), canAnnotate=\(annotations?.canAnnotate == true), pending=\(annotations?.editor.hasPendingAnnotation == true), canvas=\(annotations?.editor.conversationCanvas != nil), windows=\(NSApp.windows.map { "\(type(of: $0)): \($0.title), visible=\($0.isVisible), key=\($0.isKeyWindow)" })")
        fixtureFailure(message)
    }
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) async throws {
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(150))
    }
    func click(_ point: NSPoint, in window: NSWindow, count: Int = 1) async throws {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(150))
    }
    func openReader() async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await until("Fixture must be active before opening the reader") { NSApp.isActive && self.window.isKeyWindow }
        let button = views(window.contentView!).compactMap { $0 as? ReaderOpenAnchor.Anchor }.first!
        try await click(button.convert(.init(x: button.bounds.midX, y: button.bounds.midY), to: nil), in: window)
        try await until("Reader annotations did not attach to the popup") {
            for candidate in NSApp.windows where candidate !== self.window && candidate.isVisible {
                guard let content = candidate.contentView,
                      let host = self.views(content).compactMap({ $0 as? ConversationAnnotationHost.Host }).first,
                      let controller = host.controller, controller.markers.count == 1,
                      controller.window === candidate else { continue }
                self.reader = candidate; self.annotations = controller
                return true
            }
            return false
        }
        try await Task.sleep(for: .milliseconds(350))
        try await until("Reader shortcuts must be available immediately after opening") { self.annotations.canAnnotate }
        let text = annotations.markers.allObjects.first!
        let visible = text.bounds.intersection(text.visibleRect)
        try await click(text.convert(.init(x: visible.minX + 12, y: text.isFlipped ? visible.minY + 8 : visible.maxY - 8), to: nil), in: reader)
        try await until("Reader did not become key") { self.annotations.canAnnotate }
        require(AnnotationCommandsState.shared.conversationOwner === annotations)
        require(!parent.canAnnotate, "The chat must not intercept the reader's annotation shortcut")
    }
    func region() async throws {
        try await key("r", code: 15, flags: [.command, .shift], in: reader)
        try await until("Cmd+Shift+R did not mount the reader's region canvas") {
            self.annotations.editor.conversationCanvas?.window === self.reader
        }
        require(annotations.editor.overlay == nil && reader.isKeyWindow)
    }
    func chooseRegion() async throws {
        let canvas = annotations.editor.conversationCanvas!
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(.init(x: canvas.bounds.width * x, y: canvas.bounds.height * y), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: reader.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, 0.15, 0.25))
        canvas.mouseDragged(with: event(.leftMouseDragged, 0.7, 0.7))
        canvas.mouseUp(with: event(.leftMouseUp, 0.7, 0.7))
        try await until("Region comment did not receive focus") { self.annotations.editor.commentInput?.window?.isKeyWindow == true }
    }
    func run() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-annotation-ui-\(UUID())")
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Reviewer")
        let message = ChatMessage(conversationID: bot.conversation.id, author: .agent(bot.agent.id),
            body: "Quoted **detail** for review.\n" + String(repeating: "Another paragraph of the document.\n", count: 60), delivery: .delivered)
        try repository.append(message)
        store = NoodleStore(repository: repository, conversation: bot.conversation)
        window = NSWindow(contentRect: .init(x: 100, y: 150, width: 800, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Reader annotation test"
        window.contentView = NSHostingView(rootView: ReaderFixtureView(state: state, controller: parent, store: store, message: message))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await until("Fixture window did not become key") { self.parent.canAnnotate }
        try await openReader()
        let marker = annotations.markers.allObjects.first!
        let visible = marker.bounds.intersection(marker.visibleRect)
        let point = marker.convert(.init(x: visible.minX + 12, y: marker.isFlipped ? visible.minY + 8 : visible.maxY - 8), to: nil)
        try await click(point, in: reader, count: 2)
        try await key("a", code: 0, flags: [.command, .shift], in: reader)
        try await until("Selected reader text did not open a comment") { self.annotations.editor.commentInput?.window?.isKeyWindow == true }
        let editor = annotations.editor
        require(editor.pending?.quote == "Quoted", "Wrong selected text: \(String(describing: editor.pending?.quote))")
        require(editor.pending?.sourceMessageID == message.id)
        require(reader.isVisible && state.showing, "Comment opening dismissed the reader")
        let input = editor.commentInput!
        try await click(input.convert(.init(x: 10, y: 10), to: nil), in: input.window!)
        require(reader.isVisible && editor.commentInput === input, "Clicking the comment dismissed its reader")
        input.string = "Please explain this detail"
        try await key("\r", code: 36, flags: .command, in: input.window!)
        try await Task.sleep(for: .milliseconds(500))
        try await until("Saving must keep the reader open for further annotations") {
            self.state.showing && self.reader.isVisible && self.reader.isKeyWindow &&
                !self.annotations.editor.hasPendingAnnotation && self.annotations.canAnnotate
        }
        require(!parent.canAnnotate, "The chat must not take annotation shortcuts back after a reader save")
        require(store.saved.count == 1 && store.saved[0].attachment.annotation?.quote == "Quoted")
        require(store.saved[0].attachment.annotation?.sourceMessageID == message.id)

        try await region()
        try await chooseRegion()
        require(annotations.editor.pending?.region?.isValid == true && annotations.editor.pendingImage != nil)
        try await key("\u{1b}", code: 53, in: annotations.editor.commentInput!.window!)
        try await until("Escape must cancel the comment and leave the reader open") {
            self.reader.isVisible && self.reader.isKeyWindow && !self.annotations.editor.hasPendingAnnotation && self.annotations.canAnnotate
        }
        require(store.saved.count == 1)
        try await region()
        try await chooseRegion()
        annotations.editor.commentInput!.string = "This region needs a closer look"
        try await key("\r", code: 36, flags: .command, in: annotations.editor.commentInput!.window!)
        try await until("Region save must keep the reader open for further annotations") {
            self.state.showing && self.reader.isVisible && self.annotations.canAnnotate
        }
        require(store.saved.count == 2 && store.saved[1].attachment.annotation?.region?.isValid == true)
        require(store.saved[1].attachment.conversationID == message.conversationID)

        try await region()
        try await key("\u{1b}", code: 53, in: reader)
        try await until("Escape before region selection must keep the reader") { self.reader.isVisible && self.annotations.canAnnotate }
        try await region()
        state.showing = false
        try await until("Closing the reader should cancel annotations and disable shortcuts") {
            !self.reader.isVisible && !self.annotations.canAnnotate && !self.annotations.editor.hasPendingAnnotation
        }
        require(!annotations.editor.hasPendingAnnotation && store.saved.count == 2)
        try await openReader()
        require(!annotations.editor.hasPendingAnnotation, "Reopening the reader must not restore a cancelled annotation")
        state.showing = false
        try await until("Reader did not close") { !self.reader.isVisible }
    }
}

@main private struct ReaderAnnotationMain {
    static func main() {
        let timeout = DispatchSource.makeTimerSource(queue: .global())
        timeout.schedule(deadline: .now() + 75)
        timeout.setEventHandler { FileHandle.standardError.write(Data("FAIL: reader annotation fixture timed out\n".utf8)); exit(1) }
        timeout.resume()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ReaderAnnotationFixture(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        timeout.cancel()
    }
}
