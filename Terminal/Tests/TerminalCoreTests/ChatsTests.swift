import Foundation
import HubLink
@testable import TerminalCore
import XCTest

/// A Hub on this computer's loopback that keeps one bot's conversation and answers what the terminal asks.
final class FakeHub: @unchecked Sendable {
    let identity = LinkIdentity()
    let botID = UUID(), conversationID = UUID()
    private let lock = NSLock()
    private var stored: [LinkMessage] = []
    private var botReadUpTo: Date?
    private var botPinnedAt: Date?
    private var marks: [LinkReadMark] = []
    private var refusesSending = false
    private var portNumber: UInt16 = 0
    private var server: (any LinkListening)?
    private var received: [LinkRequest] = []
    private var answers: (@Sendable (LinkRequest) -> LinkResponse?)?
    private var uploaded: [UUID: (attachment: LinkAttachment, data: Data)] = [:]

    /// Every request the terminal sent, in order.
    var requests: [LinkRequest] { lock.withLock { received } }
    /// Answers a test gives before the Hub's own; nil leaves a request to the Hub.
    var answering: (@Sendable (LinkRequest) -> LinkResponse?)? {
        get { lock.withLock { answers } }
        set { lock.withLock { answers = newValue } }
    }
    /// The files sent up, by attachment.
    var files: [UUID: (attachment: LinkAttachment, data: Data)] {
        get { lock.withLock { uploaded } }
        set { lock.withLock { uploaded = newValue } }
    }

    var messages: [LinkMessage] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    var readUpTo: Date? {
        get { lock.withLock { botReadUpTo } }
        set { lock.withLock { botReadUpTo = newValue } }
    }
    var pinnedAt: Date? {
        get { lock.withLock { botPinnedAt } }
        set { lock.withLock { botPinnedAt = newValue } }
    }
    var readMarks: [LinkReadMark] { lock.withLock { marks } }
    var refuses: Bool {
        get { lock.withLock { refusesSending } }
        set { lock.withLock { refusesSending = newValue } }
    }
    var port: UInt16 { lock.withLock { portNumber } }

    func start() async throws {
        // The Hub's own link on each system: Network.framework's on a Mac, msquic's on Linux.
        #if os(Linux)
        let listen = QUICListener.listen(certificates: FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID())"))
        #else
        let listen = LinkServer.listen
        #endif
        let server = try listen(identity, 0, { _ in true }) { [self] _, data in
            .response(LinkProtocol.encode(answer(data)))
        }
        try await server.start()
        let port = try XCTUnwrap(server.port)
        lock.withLock {
            portNumber = port
            self.server = server
        }
    }

    func stop() { lock.withLock { server }?.stop() }

    var invitation: LinkInvitation {
        LinkInvitation(hubName: "Studio", hubKey: identity.publicKey, endpoints: [LinkEndpoint(host: "127.0.0.1", port: port)],
                       userName: "Ada", joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date().addingTimeInterval(600))
    }

    func bot(name: String = "Blake") -> LinkBot {
        LinkBot(id: botID, conversationID: conversationID, draft: LinkBotDraft(name: name, provider: "codex"),
                createdAt: Date(timeIntervalSince1970: 0), readUpTo: readUpTo, pinnedAt: pinnedAt)
    }

    func reply(_ body: String, at date: Date) -> LinkMessage {
        LinkMessage(id: UUID(), conversationID: conversationID, author: .bot(botID), body: body, createdAt: date, delivered: true)
    }

    private func answer(_ data: Data) -> LinkResponse {
        guard case .success(let request) = LinkProtocol.decode(data) else { return .failure("Unknown request") }
        let answers = lock.withLock { () -> (@Sendable (LinkRequest) -> LinkResponse?)? in
            received.append(request)
            return self.answers
        }
        if let answer = answers?(request) { return answer }
        switch request {
        case .enroll, .status:
            return .status(LinkStatus(hubName: "Studio", userName: "Ada", planName: "Default", harnesses: [],
                                      endpoints: [LinkEndpoint(host: "127.0.0.1", port: port)]))
        case .bots:
            return .bots([bot()])
        case .groups:
            return .groups([])
        case .messagePage(let page):
            let all = messages
            let from = page.after ?? page.before.map { max(0, $0 - page.limit) } ?? max(0, all.count - page.limit)
            let to = page.before ?? min(all.count, from + page.limit)
            return .messages(LinkMessages(messages: Array(all[from..<max(from, to)]), count: all.count, start: from))
        case .send(let outgoing):
            if refuses { return .failure("The Hub is full.") }
            let files = self.files
            guard outgoing.attachmentIDs.allSatisfy({ files[$0] != nil }) else { return .failure("A file is missing.") }
            let message = LinkMessage(id: outgoing.id, conversationID: outgoing.conversationID, author: .you, body: outgoing.body,
                                      createdAt: Date(), delivered: true, attachments: outgoing.attachmentIDs.compactMap { files[$0]?.attachment })
            lock.withLock { stored.append(message) }
            return .message(message)
        case .upload(_, let attachment, _, let data):
            lock.withLock { uploaded[attachment.id, default: (attachment, Data())].data.append(data) }
            return .done
        case .download(_, let id, let offset):
            guard let file = files[id] else { return .failure("No such file.") }
            return .chunk(data: file.data.dropFirst(offset).prefix(LinkProtocol.chunkSize), total: file.data.count)
        case .markRead(let mark):
            lock.withLock { marks.append(mark) }
            return .done
        case .searchMessages(let search):
            let matches = messages.filter { $0.body.localizedCaseInsensitiveContains(search.term) }.map {
                LinkMessageMatch(conversationID: $0.conversationID, messageID: $0.id, createdAt: $0.createdAt, snippet: $0.body)
            }
            return .messageMatches(matches)
        default:
            return .done
        }
    }
}

@MainActor final class ChatsTests: XCTestCase {
    var hub: FakeHub!
    var directory: URL!

    override func setUp() async throws {
        hub = FakeHub()
        try await hub.start()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        hub.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func joined() async throws -> TerminalHubs {
        let hubs = TerminalHubs(directory: directory, deviceName: "Test Terminal")
        await hubs.join(hub.invitation.url().absoluteString)
        XCTAssertNil(hubs.memberships.joinError)
        XCTAssertEqual(hubs.chats.count, 1)
        return hubs
    }

    func joinedChats() async throws -> HubChats {
        let hubs = try await joined()
        return try XCTUnwrap(hubs.chats.first)
    }

    func testJoiningAHubListsItsBotsWithTheirLatestMessages() async throws {
        hub.messages = [hub.reply("Morning", at: Date(timeIntervalSince1970: 10)), hub.reply("Ready when you are", at: Date(timeIntervalSince1970: 20))]
        let hubs = try await joined()
        let chats = try XCTUnwrap(hubs.chats.first)
        try await chats.reload()

        XCTAssertEqual(hubs.rows.map(\.thread.name), ["Blake"])
        let thread = try XCTUnwrap(hubs.rows.first?.thread)
        XCTAssertEqual(chats.messages(of: thread).map(\.body), ["Morning", "Ready when you are"])
        XCTAssertFalse(chats.hasEarlier(thread))
        // Kept between launches: a new terminal finds the Hub without joining again.
        XCTAssertEqual(TerminalHubs(directory: directory, deviceName: "Test Terminal").chats.count, 1)
    }

    func testAReplyAfterWhatWasReadIsUnreadUntilReadHere() async throws {
        hub.readUpTo = Date(timeIntervalSince1970: 10)
        hub.messages = [hub.reply("Old", at: Date(timeIntervalSince1970: 10)), hub.reply("New", at: Date(timeIntervalSince1970: 20))]
        let chats = try await joinedChats()
        try await chats.reload()
        let thread = try XCTUnwrap(chats.listedThreads.first)
        XCTAssertTrue(chats.isUnread(thread))

        chats.markRead(thread)

        XCTAssertFalse(chats.isUnread(thread))
        try await waitUntil { self.hub.readMarks.count == 1 }
        XCTAssertEqual(hub.readMarks.first?.messageID, hub.messages.last?.id)
    }

    func testReadOnAnotherDeviceIsReadHere() async throws {
        hub.messages = [hub.reply("New", at: Date(timeIntervalSince1970: 20))]
        let chats = try await joinedChats()
        try await chats.reload()
        let thread = try XCTUnwrap(chats.listedThreads.first)
        XCTAssertTrue(chats.isUnread(thread))

        try await chats.apply(.readChanged(conversationID: hub.conversationID, upTo: Date(timeIntervalSince1970: 20)))

        XCTAssertFalse(chats.isUnread(thread))
    }

    func testASentMessageIsDeliveredAsTheHubKeepsIt() async throws {
        let chats = try await joinedChats()
        try await chats.reload()
        let thread = try XCTUnwrap(chats.listedThreads.first)

        try await chats.send("  Hello  ", to: thread)

        XCTAssertEqual(chats.messages(of: thread).map(\.body), ["Hello"])
        XCTAssertEqual(chats.messages(of: thread).first?.delivered, true)
        XCTAssertNil(chats.delivery(of: try XCTUnwrap(chats.messages(of: thread).first)))
        XCTAssertEqual(hub.messages.map(\.body), ["Hello"])
    }

    func testAMessageTheHubRefusesSaysWhyAndGoesOnceTriedAgain() async throws {
        hub.refuses = true
        let chats = try await joinedChats()
        chats.retryPauses = [.zero]
        try await chats.reload()
        let thread = try XCTUnwrap(chats.listedThreads.first)

        try await chats.send("Hello", to: thread)

        let shown = try XCTUnwrap(chats.messages(of: thread).first)
        XCTAssertEqual(chats.delivery(of: shown), "Not delivered")
        XCTAssertEqual(chats.unsent[shown.id], .some("The Hub is full."))

        hub.refuses = false
        await chats.tryAgain(shown)

        XCTAssertNil(chats.delivery(of: try XCTUnwrap(chats.messages(of: thread).first)))
        XCTAssertEqual(hub.messages.map(\.id), [shown.id])
    }

    func testEarlierMessagesLoadAPageAtATime() async throws {
        hub.messages = (0..<70).map { hub.reply("Message \($0)", at: Date(timeIntervalSince1970: TimeInterval($0))) }
        let chats = try await joinedChats()
        try await chats.reload()
        let thread = try XCTUnwrap(chats.listedThreads.first)
        XCTAssertEqual(chats.messages(of: thread).count, HubChats.pageSize)
        XCTAssertTrue(chats.hasEarlier(thread))

        try await chats.loadEarlier(thread)

        XCTAssertEqual(chats.messages(of: thread).map(\.body), (0..<70).map { "Message \($0)" })
        XCTAssertFalse(chats.hasEarlier(thread))
    }

    func testANewMessageLoadsOnlyWhatCameAfterTheLast() async throws {
        hub.messages = [hub.reply("First", at: Date(timeIntervalSince1970: 1))]
        let chats = try await joinedChats()
        try await chats.reload()
        hub.messages.append(hub.reply("Second", at: Date(timeIntervalSince1970: 2)))

        try await chats.apply(.conversationChanged(conversationID: hub.conversationID, count: 2))

        let thread = try XCTUnwrap(chats.listedThreads.first)
        XCTAssertEqual(chats.messages(of: thread).map(\.body), ["First", "Second"])
    }

    func testPinnedComeFirstThenTheNewestConversation() {
        let chats = HubChats(pairing: HubPairing(directory: directory, deviceName: "Test Terminal"))
        func row(_ name: String, created: TimeInterval, pinned: TimeInterval? = nil) -> TerminalHubs.Row {
            TerminalHubs.Row(chats: chats, thread: .bot(LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: name, provider: "codex"),
                createdAt: Date(timeIntervalSince1970: created), pinnedAt: pinned.map(Date.init(timeIntervalSince1970:)))))
        }
        let rows = [row("Old", created: 1), row("New", created: 3), row("Pinned second", created: 0, pinned: 20),
                    row("Pinned first", created: 0, pinned: 10)]

        XCTAssertEqual(rows.sorted(by: TerminalHubs.isOrderedBefore).map(\.thread.name), ["Pinned first", "Pinned second", "New", "Old"])
    }

    func testSearchFindsBotsByNameAndTheMessagesThatSayTheTerm() async throws {
        hub.messages = [hub.reply("The deploy is done", at: Date(timeIntervalSince1970: 1)), hub.reply("Lunch?", at: Date(timeIntervalSince1970: 2))]
        let hubs = try await joined()
        let chats = try XCTUnwrap(hubs.chats.first)
        try await chats.reload()

        XCTAssertEqual(hubs.rows(matching: try XCTUnwrap(ConversationSearch("blak"))).map(\.thread.name), ["Blake"])
        XCTAssertEqual(hubs.rows(matching: try XCTUnwrap(ConversationSearch("deploy"))), [])
        let found = await hubs.messages(matching: try XCTUnwrap(ConversationSearch("deploy")))
        XCTAssertEqual(found.map(\.match.snippet), ["The deploy is done"])
        XCTAssertEqual(found.first?.row.thread.name, "Blake")
    }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}
