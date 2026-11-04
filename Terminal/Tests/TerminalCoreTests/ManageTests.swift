import Foundation
import HubLink
import Synchronization
@testable import TerminalCore
import XCTest

/// What a person does with their bots, groups, files and Hubs, against the same loopback Hub.
extension ChatsTests {
    private func loadedThread() async throws -> (HubChats, HubThread) {
        let chats = try await joinedChats()
        try await chats.reload()
        return (chats, try XCTUnwrap(chats.listedThreads.first))
    }

    func testPinningAsksTheHubAndPutsTheConversationFirst() async throws {
        let (chats, thread) = try await loadedThread()

        try await chats.setPinned(true, thread)

        XCTAssertNotNil(chats.thread(thread.id)?.pinnedAt)
        XCTAssertTrue(hub.requests.contains(.pin(LinkPin(conversationID: hub.conversationID, pinned: true))))
    }

    func testAPinTheHubRefusesGoesBack() async throws {
        let (chats, thread) = try await loadedThread()
        hub.answering = { request in if case .pin = request { .failure("No pins here.") } else { nil } }

        do {
            try await chats.setPinned(true, thread)
            XCTFail("The Hub refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No pins here.")
        }
        XCTAssertNil(chats.thread(thread.id)?.pinnedAt)
    }

    func testArchivingTakesTheBotOffTheListUntilBroughtBack() async throws {
        let (chats, thread) = try await loadedThread()

        try await chats.setArchived(true, thread)

        XCTAssertEqual(chats.listedThreads, [])
        XCTAssertEqual(chats.archivedThreads.map(\.id), [thread.id])
        try await chats.setArchived(false, try XCTUnwrap(chats.archivedThreads.first))
        XCTAssertEqual(chats.listedThreads.map(\.id), [thread.id])
    }

    func testAKickTheHubQuestionsIsConfirmedWithItsAnswer() async throws {
        let (chats, thread) = try await loadedThread()
        let confirmation = LinkKickConfirmation(id: UUID(), title: "Recover Blake?", message: "It was interrupted.",
                                                confirmTitle: "Recover", offersNewSession: true)
        hub.answering = { request in if case .kick = request { .kickConfirmation(confirmation) } else { nil } }
        let bot = try XCTUnwrap(thread.bot)

        let asked = try await chats.kick(bot)
        XCTAssertEqual(asked, confirmation)
        try await chats.confirmKick(confirmation, for: bot)

        XCTAssertTrue(hub.requests.contains(.confirmKick(botID: bot.id, confirmationID: confirmation.id)))
    }

    func testANewBotIsListedAndIntroducesItself() async throws {
        let (chats, _) = try await loadedThread()
        let made = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Oscar", provider: "codex"), createdAt: Date())
        hub.answering = { request in if case .createBot = request { .bot(made) } else { nil } }

        try await chats.create(LinkBotDraft(name: "Oscar", provider: "codex"))

        XCTAssertEqual(chats.bots.map(\.draft.name), ["Blake", "Oscar"])
        XCTAssertTrue(hub.requests.contains(.introduce(conversationID: made.conversationID)))
    }

    func testADeletedBotLeavesWithItsConversation() async throws {
        hub.messages = [hub.reply("Hi", at: Date(timeIntervalSince1970: 1))]
        let (chats, thread) = try await loadedThread()

        try await chats.delete(try XCTUnwrap(thread.bot))

        XCTAssertEqual(chats.bots, [])
        XCTAssertNil(chats.conversations[hub.conversationID])
    }

    func testAGroupsNotificationsShowAtOnceAndGoBackWhenRefused() async throws {
        let group = LinkGroup(id: UUID(), draft: LinkGroupDraft(name: "Team", botIDs: [hub.botID]), createdAt: Date())
        hub.answering = { request in
            switch request {
            case .groups: .groups([group])
            case .setNotifications: .failure("Not now.")
            default: nil
            }
        }
        let (chats, _) = try await loadedThread()

        do {
            try await chats.setNotifications(.muted, of: group)
            XCTFail("The Hub refused")
        } catch {}

        XCTAssertNil(chats.chosenNotifications(of: group))
        XCTAssertTrue(hub.requests.contains(.setNotifications(LinkNotificationsChange(conversationID: group.id, notifications: .muted))))
    }

    func testAFileGoesUpBeforeItsMessage() async throws {
        let (chats, thread) = try await loadedThread()
        let file = directory.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Remember the milk".utf8).write(to: file)

        try await chats.send("", files: [file], to: thread)

        let sent = try XCTUnwrap(chats.messages(of: thread).last)
        XCTAssertEqual(sent.body, "Sent 1 attachment")
        XCTAssertNil(chats.delivery(of: sent))
        XCTAssertEqual(sent.attachments.map(\.filename), ["notes.txt"])
        XCTAssertEqual(sent.attachments.first?.mediaType, "text/plain")
        XCTAssertEqual(hub.files.values.map { String(decoding: $0.data, as: UTF8.self) }, ["Remember the milk"])
    }

    func testADownloadedFileTakesAFreeName() async throws {
        let (chats, thread) = try await loadedThread()
        let attachment = LinkAttachment(id: UUID(), filename: "report.pdf", mediaType: "application/pdf", byteCount: 5)
        hub.files = [attachment.id: (attachment, Data("hello".utf8))]
        let message = LinkMessage(id: UUID(), conversationID: thread.conversationID, author: .bot(hub.botID), body: "",
                                  createdAt: Date(), delivered: true, attachments: [attachment])
        let folder = directory.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("report.pdf"))

        let saved = try await chats.download(attachment, of: message, into: folder)

        XCTAssertEqual(saved.lastPathComponent, "report 2.pdf")
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "hello")
    }

    func testAToolIsAssignedAlongsideTheOnesTheBotHas() async throws {
        let first = UUID(), second = UUID()
        let computers = Mutex([LinkComputer(id: first, name: "Studio", kind: "linux", state: "running", symbol: "desktopcomputer", colour: 0,
                                            botIDs: [hub.botID]),
                               LinkComputer(id: second, name: "Lab", kind: "linux", state: "stopped", symbol: "desktopcomputer", colour: 1)])
        let botID = hub.botID
        hub.answering = { request in
            switch request {
            case .computers: return .computers(computers.withLock { $0 })
            case .assignComputers(_, let ids):
                computers.withLock { list in
                    for index in list.indices {
                        list[index].botIDs = ids.contains(list[index].id) ? [botID] : []
                    }
                }
                return .done
            default: return nil
            }
        }
        let (chats, thread) = try await loadedThread()
        let bot = try XCTUnwrap(thread.bot)

        try await chats.setAssigned(true, .computer, second, for: bot)

        XCTAssertEqual(chats.tools(.computer, for: bot).map(\.assigned), [true, true])
        let assigned: [Set<UUID>] = hub.requests.compactMap { if case .assignComputers(_, let ids) = $0 { Set(ids) } else { nil } }
        XCTAssertEqual(assigned, [[first, second]])
    }

    func testSpacesShowEveryHubOrOne() async throws {
        let hubs = try await joined()
        let chats = try XCTUnwrap(hubs.chats.first)
        try await chats.reload()
        XCTAssertEqual(hubs.spaces, [.all, .hub(chats.id)])

        hubs.space = .hub(chats.id)
        XCTAssertEqual(hubs.rows.map(\.thread.name), ["Blake"])
        XCTAssertEqual(hubs.name(of: hubs.space), "Studio")

        hubs.leave(chats)

        XCTAssertEqual(hubs.space, .all)
        XCTAssertEqual(hubs.chats.count, 0)
        XCTAssertEqual(hubs.rows.count, 0)
    }
}
