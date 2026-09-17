import AppKit
import Observation
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class ConversationWindowTests: XCTestCase {
    private func fixture() throws -> (NoodleStore, BotConversation, BotConversation) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-windows-\(UUID())")
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Window Bot")
        let group = try repository.createGroup(named: "Window Group", participantIDs: [bot.agent.id], existingAgents: [bot.agent])
        let suite = "noodle-window-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(homeDirectory: root,
            applicationsDirectory: root, executableSearchDirectories: [], applicationBundleURL: root), defaults: defaults)
        let store = NoodleStore(repository: repository, runtime: runtime, connectsServices: false)
        XCTAssertTrue(store.storageReady, store.errorMessage ?? "Storage failed")
        addTeardownBlock { @MainActor in
            store.stopMonitoring()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return (store, bot.conversation, group)
    }

    func testSendAndPasteTargetDisplayedConversationWhileMainSelectionChanges() throws {
        let (store, direct, group) = try fixture()
        store.selectedConversationID = direct.id
        store.setDraft("Direct draft", for: direct.id)
        store.setDraft("Group draft", for: group.id)
        let file = store.repository.rootURL.appendingPathComponent("Fixture.txt")
        try Data("An attachment".utf8).write(to: file)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([file as NSURL]))
        XCTAssertTrue(store.importAttachmentsFromPasteboard(into: group.id, pasteboard: board))
        XCTAssertTrue(store.pendingAttachments(for: direct.id).isEmpty)
        let attachment = try XCTUnwrap(store.pendingAttachments(for: group.id).first)

        store.sendDraft(to: group.id)
        let sent = try XCTUnwrap(store.messages(for: group).last)
        XCTAssertEqual(sent.conversationID, group.id)
        XCTAssertEqual(sent.body, "Group draft")
        XCTAssertEqual(sent.attachments, [attachment.id])
        XCTAssertEqual(store.draft(for: direct.id), "Direct draft")
        XCTAssertTrue(store.draft(for: group.id).isEmpty)
        XCTAssertTrue(store.pendingAttachments(for: group.id).isEmpty)
        XCTAssertEqual(store.selectedConversationID, direct.id)
        let count = store.messages(for: group).count
        store.sendDraft(to: group.id)
        XCTAssertEqual(store.messages(for: group).count, count, "The other window must not resend a cleared draft")

        store.selectedConversationID = group.id
        store.sendDraft(to: direct.id)
        XCTAssertEqual(store.messages(for: direct).last?.body, "Direct draft")
        XCTAssertEqual(store.selectedConversationID, group.id)
    }

    func testIncomingMessagesAndGroupEditsInvalidateBothReaders() throws {
        let (store, direct, group) = try fixture()
        let first = expectation(description: "Main reader updated")
        let second = expectation(description: "Separate reader updated")
        for changed in [first, second] {
            withObservationTracking {
                _ = store.messages(for: group)
            } onChange: { changed.fulfill() }
        }
        let reply = ChatMessage(conversationID: group.id, author: .agent(direct.participantIDs[0]),
            body: "Shared reply", delivery: .delivered)
        try store.repository.append(reply)
        store.refreshTranscripts()
        wait(for: [first, second], timeout: 1)
        XCTAssertTrue(store.messages(for: group).contains { $0.id == reply.id })
        XCTAssertTrue(store.updateGroup(group, named: "Renamed Group", publicDescription: "Shared details",
            participantIDs: Set(group.participantIDs)))
        XCTAssertEqual(store.conversations.first { $0.id == group.id }?.displayName, "Renamed Group")
        XCTAssertTrue(store.delete(group))
        store.sendDraft(to: group.id)
        XCTAssertFalse(store.conversations.contains { $0.id == group.id })
    }

    func testTwoMountedChatViewsSynchronizeDraftsAndKeepIndependentEditors() async throws {
        let (store, direct, group) = try fixture()
        store.selectedConversationID = direct.id
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ConversationWindowView(conversationID: group.id)
                .environment(store).preferredColorScheme(.dark))
            window.contentView?.layoutSubtreeIfNeeded()
            return window
        }
        let main = window(), separate = window()
        defer { main.close(); separate.close(); main.contentView = nil; separate.contentView = nil }
        func editor(in view: NSView?) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view?.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        for _ in 0..<100 where editor(in: main.contentView) == nil || editor(in: separate.contentView) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try XCTUnwrap(editor(in: main.contentView))
        let second = try XCTUnwrap(editor(in: separate.contentView))
        XCTAssertFalse(first === second)
        first.string = "Written in the first window"
        first.didChangeText()
        for _ in 0..<100 where second.string != first.string { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(second.string, "Written in the first window")
        XCTAssertEqual(store.draft(for: direct.id), "")
        second.string = "Edited in the second window"
        second.didChangeText()
        for _ in 0..<100 where first.string != second.string { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(first.string, "Edited in the second window")
        second.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        for _ in 0..<100 where !first.string.isEmpty || !second.string.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.messages(for: group).last?.body, "Edited in the second window")
        XCTAssertTrue(first.string.isEmpty)
        XCTAssertTrue(second.string.isEmpty)
        XCTAssertTrue(store.messages(for: direct).isEmpty)
    }

    func testRapidConversationSwitchesPreserveTheFocusedComposerAndDraftDestination() async throws {
        let (store, direct, group) = try fixture()
        store.selectedConversationID = direct.id
        store.setDraft("Direct draft", for: direct.id)
        store.setDraft("Group draft", for: group.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SwitchingChatFixture(store: store))
        defer { window.close(); window.contentView = nil }
        func editor(in view: NSView?) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view?.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        for _ in 0..<100 where editor(in: window.contentView) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let originalEditor = try XCTUnwrap(editor(in: window.contentView))
        XCTAssertTrue(window.makeFirstResponder(originalEditor))
        for index in 0..<20 {
            let selected = index.isMultiple(of: 2) ? group : direct
            store.selectedConversationID = selected.id
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertTrue(editor(in: window.contentView) === originalEditor)
            XCTAssertTrue(window.firstResponder === originalEditor)
            XCTAssertEqual(originalEditor.string, store.draft(for: selected.id))
        }
        originalEditor.string = "Edited after rapid navigation"
        originalEditor.didChangeText()
        XCTAssertEqual(store.draft(for: direct.id), originalEditor.string)
        XCTAssertEqual(store.draft(for: group.id), "Group draft")
    }

    func testWindowRegistryRemovesClosedWindowsAndTracksMainSelection() {
        let registry = ConversationWindowRegistry()
        let firstID = UUID(), nextID = UUID()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = ConversationWindowHost.Probe(registry: registry)
        host.conversationID = firstID
        window.contentView = host
        XCTAssertTrue(registry.focus(firstID))
        host.conversationID = nextID
        XCTAssertFalse(registry.focus(firstID))
        XCTAssertTrue(registry.focus(nextID))
        var opened: UUID?
        host.openConversation = { opened = $0 }
        NotificationCenter.default.post(name: .openConversation, object: firstID)
        XCTAssertEqual(opened, firstID, "A remaining separate window must route other conversations")
        opened = nil
        NotificationCenter.default.post(name: .openConversation, object: nextID)
        XCTAssertNil(opened, "An existing conversation window must be reused")
        window.close()
        XCTAssertFalse(registry.focus(nextID))
    }

    func testConversationInteractionClearsAndPersistsUnreadWithoutChangingSelection() throws {
        let (store, direct, group) = try fixture()
        store.selectedConversationID = direct.id
        let main = mount(direct.id, in: store.conversationWindows, isMain: true)
        let separate = mount(group.id, in: store.conversationWindows)
        defer { main.close(); separate.close() }
        let interactions: [NSEvent.EventType] = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .keyDown, .scrollWheel, .magnify, .smartMagnify, .rotate, .swipe, .pressure
        ]
        for window in [main, separate] {
            let host = try XCTUnwrap(window.contentView as? ConversationWindowHost.Probe)
            host.markRead = store.markConversationRead
            let conversationID = try XCTUnwrap(host.conversationID)
            let otherID = conversationID == direct.id ? group.id : direct.id
            for type in interactions {
                for conversation in [direct, group] {
                    try store.repository.append(ChatMessage(conversationID: conversation.id,
                        author: .agent(direct.participantIDs[0]), body: "Unread reply", delivery: .delivered))
                }
                store.refreshTranscripts()
                XCTAssertEqual(store.unreadConversationIDs, [direct.id, group.id])
                host.handleInteraction(ConversationInteractionEvent(type: type, window: window))
                XCTAssertEqual(store.unreadConversationIDs, [otherID], "\(type)")
                XCTAssertEqual(try store.repository.loadUnreadConversationIDs(), [otherID])
                XCTAssertEqual(NSApplication.shared.dockTile.badgeLabel, "1")
                XCTAssertEqual(store.selectedConversationID, direct.id)
                store.refreshTranscripts()
                XCTAssertEqual(store.unreadConversationIDs, [otherID], "Refreshing must preserve read state")
            }
        }
    }

    func testInteractionIgnoresOtherWindowsPassiveEventsAndClosedOrDetachedHosts() throws {
        let registry = ConversationWindowRegistry(fileURL: sessionURL())
        let window = mount(UUID(), in: registry)
        let other = mount(UUID(), in: registry)
        defer { window.close(); other.close() }
        let host = try XCTUnwrap(window.contentView as? ConversationWindowHost.Probe)
        var read: [UUID?] = []
        host.markRead = { read.append($0) }
        host.handleInteraction(ConversationInteractionEvent(type: .keyDown, window: other))
        for type: NSEvent.EventType in [.mouseMoved, .mouseEntered, .mouseExited, .flagsChanged, .applicationDefined] {
            host.handleInteraction(ConversationInteractionEvent(type: type, window: window))
        }
        XCTAssertTrue(read.isEmpty)
        let nextID = UUID()
        host.conversationID = nextID
        host.handleInteraction(ConversationInteractionEvent(type: .leftMouseDown, window: window))
        XCTAssertEqual(read, [nextID], "Input must follow the currently displayed conversation")
        read.removeAll()
        window.close()
        host.handleInteraction(ConversationInteractionEvent(type: .keyDown, window: window))
        XCTAssertTrue(read.isEmpty)
        window.contentView = nil
        host.handleInteraction(ConversationInteractionEvent(type: .scrollWheel, window: window))
        XCTAssertTrue(read.isEmpty)
    }

    func testLocalInteractionMonitorPreservesKeyboardDeliveryAndDetachesWithHost() throws {
        let registry = ConversationWindowRegistry(fileURL: sessionURL())
        let id = UUID()
        let window = ConversationInputWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = ConversationWindowHost.Probe(registry: registry)
        host.conversationID = id
        host.isMainWindow = true
        window.contentView = host
        XCTAssertTrue(registry.focus(id))
        var read: [UUID?] = []
        host.markRead = { read.append($0) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        NSApplication.shared.sendEvent(event)
        XCTAssertEqual(read, [id])
        XCTAssertEqual(window.receivedEvent?.type, .keyDown, "Reading must not consume the input")
        XCTAssertEqual(window.receivedEvent?.characters, "a")
        read.removeAll()
        window.contentView = nil
        NSApplication.shared.sendEvent(event)
        XCTAssertTrue(read.isEmpty)
    }

    private func sessionURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-window-session-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("conversation-windows.json")
    }

    private func mount(_ id: UUID, in registry: ConversationWindowRegistry, isMain: Bool = false) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 80, y: 80, width: 620, height: 510),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = ConversationWindowHost.Probe(registry: registry)
        host.conversationID = id
        host.isMainWindow = isMain
        window.contentView = host
        host.updateWindow()
        return window
    }

    func testOpenWindowsAndMovedFramesSurviveWithoutTerminationCallback() throws {
        let file = sessionURL(), first = UUID(), second = UUID(), mainOnly = UUID()
        let registry = ConversationWindowRegistry(fileURL: file)
        let firstWindow = mount(first, in: registry)
        let secondWindow = mount(second, in: registry)
        let mainWindow = mount(mainOnly, in: registry, isMain: true)
        defer { firstWindow.close(); secondWindow.close(); mainWindow.close() }
        firstWindow.setFrame(.init(x: 100, y: 100, width: 660, height: 560), display: false)

        // Read from disk while the original process is still alive: no Quit flush.
        let relaunched = ConversationWindowRegistry(fileURL: file)
        relaunched.retainConversations([first, second, mainOnly])
        let selectedMain = mount(first, in: relaunched, isMain: true)
        defer { selectedMain.close() }
        var opened: [UUID] = []
        relaunched.restoreWindows { opened.append($0) }
        XCTAssertEqual(Set(opened), [first, second], "Main selection must neither add nor suppress a pop-out")
        relaunched.restoreWindows { opened.append($0) }
        XCTAssertEqual(opened.count, 2, "Reopening the main window must not repeat restoration")

        let restored = mount(first, in: relaunched)
        defer { restored.close() }
        XCTAssertEqual(restored.frame, firstWindow.frame)
    }

    func testExplicitClosePersistsAndLateCallbacksCannotReopenIt() throws {
        let file = sessionURL(), closedID = UUID(), openID = UUID()
        let registry = ConversationWindowRegistry(fileURL: file)
        let closed = mount(closedID, in: registry), open = mount(openID, in: registry)
        defer { open.close() }
        let host = try XCTUnwrap(closed.contentView as? ConversationWindowHost.Probe)
        closed.close()
        host.updateWindow()
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: closed)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: closed)
        XCTAssertFalse(registry.focus(closedID))

        var reopened: [UUID] = []
        ConversationWindowRegistry(fileURL: file).restoreWindows { reopened.append($0) }
        XCTAssertEqual(reopened, [openID])
    }

    func testQuitKeepsPopoutsEvenWhenAppKitClosesTheirWindows() throws {
        let (store, direct, group) = try fixture()
        let first = mount(direct.id, in: store.conversationWindows)
        let second = mount(group.id, in: store.conversationWindows)
        XCTAssertEqual(AppDelegate().applicationShouldTerminate(NSApplication.shared), .terminateNow)
        first.close()
        second.close()

        let relaunched = ConversationWindowRegistry(fileURL: store.repository.rootURL.appendingPathComponent("conversation-windows.json"))
        var opened: [UUID] = []
        relaunched.restoreWindows { opened.append($0) }
        XCTAssertEqual(Set(opened), [direct.id, group.id])
    }

    func testDeletedConversationIsPrunedAndCannotBeSavedByAnOldHost() throws {
        let (store, direct, group) = try fixture()
        let first = mount(direct.id, in: store.conversationWindows)
        let second = mount(group.id, in: store.conversationWindows)
        defer { first.close(); second.close() }
        XCTAssertTrue(store.delete(group))
        (second.contentView as? ConversationWindowHost.Probe)?.updateWindow()
        let file = store.repository.rootURL.appendingPathComponent("conversation-windows.json")
        var reopened: [UUID] = []
        ConversationWindowRegistry(fileURL: file).restoreWindows { reopened.append($0) }
        XCTAssertEqual(reopened, [direct.id])
    }

    func testRestorationPrunesMissingConversationsAndToleratesCorruptState() throws {
        let file = sessionURL(), valid = UUID(), deleted = UUID()
        let session = ConversationWindowSession(fileURL: file)
        session.save(frame: "", for: valid)
        session.save(frame: "", for: deleted)
        let relaunched = ConversationWindowRegistry(fileURL: file)
        relaunched.retainConversations([valid])
        var opened: [UUID] = []
        relaunched.restoreWindows { opened.append($0) }
        XCTAssertEqual(opened, [valid])
        XCTAssertEqual(Set(ConversationWindowSession(fileURL: file).frames.keys), [valid])

        try Data("partial data".utf8).write(to: file)
        let recovered = ConversationWindowRegistry(fileURL: file)
        recovered.restoreWindows { _ in XCTFail("Corrupt state must not open a window") }
        let window = mount(valid, in: recovered)
        defer { window.close() }
        XCTAssertEqual(Set(ConversationWindowSession(fileURL: file).frames.keys), [valid])
    }
}

@MainActor final class ConversationReadIntegrationTests: HiddenViewTests {
    func testActiveChatClearsUnreadRepliesAndFollowsConversationChangesWithoutAWindowProbe() async throws {
        let f = try fixture()
        let preview = AttachmentPreviewController()
        func chat(_ conversation: BotConversation, state: ControlActiveState) -> some View {
            ChatView(conversation: conversation, attachmentPreview: preview)
                .environment(f.store).environment(\.controlActiveState, state)
        }
        for conversation in [f.directA, f.directB] {
            try f.repository.append(ChatMessage(conversationID: conversation.id, author: .agent(f.a.id),
                body: "Unread reply", delivery: .delivered))
        }
        f.store.refreshTranscripts()
        let root = host(chat(f.directA, state: .inactive))
        try await wait { self.elements(root).contains { $0 is ComposerTextView } }
        XCTAssertEqual(f.store.unreadConversationIDs, [f.directA.id, f.directB.id], "Inactive chats remain unread")

        root.rootView = chat(f.directA, state: .key)
        try await wait { !f.store.hasUnreadMessages(in: f.directA) }
        XCTAssertEqual(f.store.unreadConversationIDs, [f.directB.id])
        try f.repository.append(ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id),
            body: "Another reply while reading", delivery: .delivered))
        f.store.refreshTranscripts()
        try await wait { !f.store.hasUnreadMessages(in: f.directA) }
        XCTAssertEqual(try f.repository.loadUnreadConversationIDs(), [f.directB.id])

        root.rootView = chat(f.directB, state: .key)
        try await wait { f.store.unreadConversationIDs.isEmpty }
        XCTAssertTrue(try f.repository.loadUnreadConversationIDs().isEmpty)
    }

    func testScrollingTheTranscriptClearsUnreadWithoutAWindowProbe() async throws {
        let f = try fixture()
        for index in 0..<40 {
            try f.repository.append(ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id),
                body: "Reply \(index)", delivery: .delivered))
        }
        f.store.refreshTranscripts()
        let root = host(ChatView(conversation: f.directA, attachmentPreview: AttachmentPreviewController())
            .environment(f.store).environment(\.controlActiveState, .inactive))
        try await wait { self.elements(root).contains { $0 is ComposerTextView } }
        let scroll = try XCTUnwrap(elements(root).compactMap { $0 as? NSScrollView }
            .first { !($0 is ComposerScrollView) })
        XCTAssertTrue(f.store.hasUnreadMessages(in: f.directA), "Restoring the scroll position must not mark it read")
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: 100, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        try await wait { !f.store.hasUnreadMessages(in: f.directA) }
        XCTAssertTrue(try f.repository.loadUnreadConversationIDs().isEmpty)
    }

    func testMainWindowMountsReadTrackingAndClearsUnreadOnInput() async throws {
        let f = try fixture()
        f.store.selectedConversationID = f.directA.id
        let root = host(RootView().environment(f.store))
        try await wait { self.elements(root).contains { $0 is ComposerTextView } }
        let probes = elements(root).compactMap { $0 as? ConversationWindowHost.Probe }
        XCTAssertEqual(probes.count, 1, "The actual split-view window must mount its read-state observer")
        let probe = try XCTUnwrap(probes.first)
        XCTAssertEqual(probe.conversationID, f.directA.id)
        XCTAssertTrue(probe.window === root.window)
        for conversation in [f.directA, f.directB] {
            try f.repository.append(ChatMessage(conversationID: conversation.id, author: .agent(f.a.id),
                body: "Incoming reply", delivery: .delivered))
        }
        f.store.refreshTranscripts()
        XCTAssertEqual(f.store.unreadConversationIDs, [f.directA.id, f.directB.id])
        let window = try XCTUnwrap(root.window)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        NSApplication.shared.sendEvent(event)
        XCTAssertEqual(f.store.unreadConversationIDs, [f.directB.id])
        XCTAssertEqual(try f.repository.loadUnreadConversationIDs(), [f.directB.id])
    }
}

private final class ConversationInteractionEvent: NSEvent {
    private let interactionType: NSEvent.EventType
    private let interactionWindow: NSWindow
    override var type: NSEvent.EventType { interactionType }
    override var window: NSWindow? { interactionWindow }
    init(type: NSEvent.EventType, window: NSWindow) {
        interactionType = type
        interactionWindow = window
        super.init()
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor private final class ConversationInputWindow: NSWindow {
    var receivedEvent: NSEvent?
    override func sendEvent(_ event: NSEvent) { receivedEvent = event }
}

private struct SwitchingChatFixture: View {
    let store: NoodleStore
    @State private var preview = AttachmentPreviewController()
    var body: some View {
        if let conversation = store.selectedConversation {
            ChatView(conversation: conversation, attachmentPreview: preview)
                .environment(store)
        }
    }
}
