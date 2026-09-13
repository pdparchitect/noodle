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
