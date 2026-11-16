import HubLink
import NoodleCore
import NoodleRuntimeSettings
import XCTest

/// Noodle's sidebar order in Pion: pins on top in the order pinned and kept across launches, an Unread section
/// when chosen, and the rest newest message first, with Investigations still by severity.
@MainActor final class SidebarTests: XCTestCase {
    func testPinsSitOnTopAndTheRestIsNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionSidebar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let blake = try model.createAgent(name: "Blake", description: nil, instructions: "", provider: .codex, model: nil)
        let averyChat = try XCTUnwrap(model.directConversation(of: avery))
        let blakeChat = try XCTUnwrap(model.directConversation(of: blake))
        let team = try model.createGroup(name: "Team", description: nil, members: [avery.id, blake.id])
        let case1 = try model.open(PionModel.Draft(title: "Beaconing laptop", lead: avery.id))
        model.selection = nil

        _ = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: averyChat.id, body: "Old.", now: Date(timeIntervalSinceNow: -60))
        _ = try model.repository.sendAgentMessage(agentID: blake.id, conversationID: blakeChat.id, body: "New.", now: Date(timeIntervalSinceNow: -30))
        model.refresh()
        model.markRead(averyChat.id)
        model.markRead(blakeChat.id)

        var sections = model.sidebarSections(.newestFirst)
        XCTAssertEqual(sections.agents.map(\.id), [blakeChat.id, averyChat.id], "Newest message first")
        XCTAssertEqual(sections.groups.map(\.id), [team.id])
        XCTAssertEqual(sections.investigations.map(\.id), [case1.id])

        model.setPinned(true, conversationID: team.id)
        model.setPinned(true, conversationID: averyChat.id)
        sections = model.sidebarSections(.newestFirst)
        XCTAssertEqual(sections.pinned.map(\.id), [team.id, averyChat.id], "In the order pinned")
        XCTAssertEqual(sections.agents.map(\.id), [blakeChat.id])
        XCTAssertEqual(sections.groups, [])

        _ = try model.repository.sendAgentMessage(agentID: blake.id, conversationID: blakeChat.id, body: "Newer.")
        model.refresh()
        sections = model.sidebarSections(.unreadSection)
        XCTAssertEqual(sections.unread.map(\.id), [blakeChat.id])
        XCTAssertEqual(sections.agents, [])
        XCTAssertEqual(model.rowDetail(for: blakeChat, showing: .latestMessage), "Newer.")

        let reopened = PionModel(root: root, messenger: nil, isScripted: true)
        reopened.start()
        XCTAssertEqual(reopened.sidebarSections(.newestFirst).pinned.map(\.id), [team.id, averyChat.id], "Kept across launches")
        reopened.setPinned(false, conversationID: team.id)
        XCTAssertFalse(reopened.isPinned(team.id))
    }

    func testSearchFindsNamesFirstThenMessages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionSearch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let blake = try model.createAgent(name: "Blake", description: "Beacon hunting", instructions: "", provider: .codex, model: nil)
        let chat = try XCTUnwrap(model.directConversation(of: avery))
        let investigation = try model.open(PionModel.Draft(title: "Beaconing laptop", lead: avery.id))
        _ = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: chat.id, body: "Saw a **beacon** to 10.0.0.9.")
        model.refresh()

        let finder = MentionFinder()
        finder.delay = .zero
        model.findMentions("beacon", with: finder)
        let names = try XCTUnwrap(model.sidebarSearch("beacon", showingAll: true, mentions: finder))
        XCTAssertTrue(names.isFindingMentions, "As in Noodle, what was said is found off the main thread")
        XCTAssertEqual(names.investigations.map(\.id), [investigation.id], "Names at once")
        XCTAssertFalse(names.isEmpty)
        await finder.task?.value
        let search = try XCTUnwrap(model.sidebarSearch("beacon", showingAll: true, mentions: finder))
        XCTAssertFalse(search.isFindingMentions)
        XCTAssertEqual(search.investigations.map(\.id), [investigation.id], "By title")
        XCTAssertEqual(search.agents.map(\.id), [try XCTUnwrap(model.directConversation(of: blake)).id], "By description")
        let mention = try XCTUnwrap(search.mentions.first { $0.conversationID == chat.id })
        XCTAssertEqual(mention.snippet, "Saw a beacon to 10.0.0.9.", "Without its markdown")
        XCTAssertNil(model.sidebarSearch("  ", showingAll: false, mentions: finder))
    }

    /// As in Noodle: a message opened from search or a notification is where its transcript opens, even one not on
    /// screen yet, and the latest message is the bottom, which keeps following new replies. Places outlast a launch.
    func testAnOpenedMessageIsWhereTheTranscriptOpensAndPlacesAreKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionReveal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let chat = try XCTUnwrap(model.directConversation(of: avery))
        let first = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: chat.id, body: "First.")
        let latest = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: chat.id, body: "Latest.")
        model.refresh()

        model.revealMessage(first.id, in: chat.id)
        XCTAssertEqual(model.transcriptViewport(for: chat.id), TranscriptViewport(isAtBottom: false, messageID: first.id))
        model.revealMessage(latest.id, in: chat.id)
        XCTAssertEqual(model.transcriptViewport(for: chat.id), TranscriptViewport())

        model.saveTranscriptViewport(TranscriptViewport(offset: 40, isAtBottom: false, messageID: first.id), for: chat.id)
        let reopened = PionModel(root: root, messenger: nil, isScripted: true)
        reopened.start()
        XCTAssertEqual(reopened.transcriptViewport(for: chat.id).messageID, first.id)
    }

    /// As in Noodle: a name kept from before names had a limit shows its first line, shortened when long.
    func testTitlesShowANamesFirstLineShortened() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionSidebar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        var group = try model.createGroup(name: "Team", description: nil, members: [avery.id])
        group.displayName = "Night shift\nsecond line"
        try model.repository.updateConversation(group)
        model.refresh()
        XCTAssertEqual(model.title(of: try XCTUnwrap(model.conversation(group.id))), "Night shift")
        group.displayName = String(repeating: "a", count: 300)
        try model.repository.updateConversation(group)
        model.refresh()
        XCTAssertEqual(model.title(of: try XCTUnwrap(model.conversation(group.id))), ConversationName.display(group.displayName))
        XCTAssertLessThan(model.title(of: group).count, 300)
    }
}


extension PionModel {
    /// The sidebar's search once what was said has been found.
    func searched(_ text: String) async -> SidebarSearch? {
        let finder = MentionFinder()
        finder.delay = .zero
        findMentions(text, with: finder)
        await finder.task?.value
        return sidebarSearch(text, showingAll: true, mentions: finder)
    }
}
