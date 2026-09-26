import BrowserBridge
import Foundation
import HubCore
import HubLink
import NoodleCore
import NoodleRuntime
import XCTest

/// Noodle serving its own owner's devices: the bots already on the Mac, with nobody else to share them.
@MainActor final class PersonalHubTests: XCTestCase {
    private struct Fixture {
        let personal: PersonalHub
        let repository: WorkspaceRepository
        let device: HubPairing
    }

    private func fixture(bots names: [String]) async throws -> (Fixture, [AgentRecord]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-personal-hub-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        try repository.prepare()
        // Bots made in Noodle before it served anyone.
        let made = try names.map { try repository.createAgent(named: $0).agent }
        let runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(managedHarnesses: repository.managedHarnesses))
        let personal = PersonalHub(name: "Studio", directory: root.appendingPathComponent("Remote"), repository: repository,
                                   runtime: runtime, applets: AppletController(repository: repository),
                                   profiles: HarnessProfilesController(store: repository.harnessProfiles), port: 0,
                                   localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await personal.start()
        addTeardownBlock { await MainActor.run { personal.stop() } }
        guard case .listening = personal.link.state else { throw XCTSkip("Could not listen: \(personal.link.state)") }
        let device = HubPairing(directory: root.appendingPathComponent("Phone"), deviceName: "iPhone")
        await device.join(personal.link.invite(personal.owner).url().absoluteString)
        XCTAssertNil(device.error)
        return (Fixture(personal: personal, repository: repository, device: device), made)
    }

    func testAPhoneSeesTheBotsAlreadyOnTheMacAndTalksToThem() async throws {
        let (f, made) = try await fixture(bots: ["Kai", "Eli"])
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertEqual(Set(bots.map(\.id)), Set(made.map(\.id)))

        let kai = try XCTUnwrap(bots.first { $0.id == made[0].id })
        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: kai.conversationID, id: UUID(), body: "Hello from the phone")))
        XCTAssertEqual(try f.repository.loadMessages(conversationID: kai.conversationID).map(\.body), ["Hello from the phone"])

        // A bot made on the Mac later shows up too.
        let later = try f.repository.createAgent(named: "Cass").agent
        guard case .bots(let now) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertTrue(now.contains { $0.id == later.id })
    }

    /// A phone joining later reads the conversations as they already are.
    func testAPhoneReadsTheConversationsAlreadyOnTheMac() async throws {
        let (f, made) = try await fixture(bots: ["Eli"])
        let conversation = try XCTUnwrap(f.repository.loadConversations().first { $0.participantIDs == [made[0].id] })
        _ = try f.repository.sendUserMessage(conversationID: conversation.id, body: "Hi there")
        _ = try f.repository.sendAgentMessage(agentID: made[0].id, conversationID: conversation.id, body: "Hey, how are you?")
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        let eli = try XCTUnwrap(bots.first)
        XCTAssertEqual(eli.conversationID, conversation.id)
        guard case .messages(let page) = try await f.device.request(.messages(conversationID: eli.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.map(\.body), ["Hi there", "Hey, how are you?"])
    }

    /// A long conversation, well past what one answer may carry, arrives newest first and page by
    /// page as the person scrolls back; a device reading onward gets the rest the same way.
    func testALongConversationArrivesPageByPage() async throws {
        let (f, made) = try await fixture(bots: ["Eli"])
        let conversation = try XCTUnwrap(f.repository.loadConversations().first { $0.participantIDs == [made[0].id] })
        let long = String(repeating: "The little bookshop at the end of the street opened at nine. ", count: 800)
        for index in 0..<40 { _ = try f.repository.sendAgentMessage(agentID: made[0].id, conversationID: conversation.id, body: "\(index) \(long)") }
        func page(_ request: LinkMessagePage) async throws -> LinkMessages {
            guard case .messages(let page) = try await f.device.request(.messagePage(request)) else { throw LinkError("no messages") }
            return page
        }
        func numbers(_ page: LinkMessages) -> [Int] { page.messages.compactMap { $0.body.split(separator: " ").first.flatMap { Int($0) } } }

        var newest = try await page(LinkMessagePage(conversationID: conversation.id))
        XCTAssertEqual(newest.count, 40)
        XCTAssertLessThan(newest.messages.count, 40, "the whole conversation came at once")
        XCTAssertEqual(numbers(newest).last, 39, "the first page was not the newest")
        var seen = numbers(newest)
        while let start = newest.start, start > 0 {
            newest = try await page(LinkMessagePage(conversationID: conversation.id, before: start))
            seen = numbers(newest) + seen
        }
        XCTAssertEqual(seen, Array(0..<40))

        var onward: [Int] = [], at = 0
        while at < 40 {
            let next = try await page(LinkMessagePage(conversationID: conversation.id, after: at))
            onward += numbers(next)
            at += next.messages.count
        }
        XCTAssertEqual(onward, Array(0..<40))
    }

    /// Pages leave card pictures out; each card's picture comes on its own when it is shown.
    func testCardPicturesComeOnTheirOwn() async throws {
        let (f, made) = try await fixture(bots: ["Kai"])
        let conversation = try XCTUnwrap(f.repository.loadConversations().first { $0.participantIDs == [made[0].id] })
        let picture = Data(repeating: 7, count: 400_000)
        let card = try f.repository.importLinkAttachment(BrowserLink.url(browser: UUID(), tab: UUID()), into: conversation.id,
                                                          card: LinkCard(title: "Hacker News", detail: "https://news.ycombinator.com", image: picture))
        _ = try f.repository.sendAgentMessage(agentID: made[0].id, conversationID: conversation.id, body: "Here", attachmentIDs: [card.id])
        guard case .messages(let page) = try await f.device.request(.messagePage(LinkMessagePage(conversationID: conversation.id))) else {
            return XCTFail("no messages")
        }
        let listed = try XCTUnwrap(page.messages.last?.attachments.first)
        XCTAssertEqual(listed.card?.title, "Hacker News")
        XCTAssertNil(listed.card?.image, "a page carried a card's picture")
        let fetched = try await f.device.request(.linkPreview(conversationID: conversation.id, attachmentID: card.id))
        XCTAssertEqual(fetched, .picture(picture))
    }

    /// Copies of bots the owner keeps on another Hub are that Hub's, not this Mac's.
    func testBotsOfAnotherHubStayHidden() async throws {
        let (f, made) = try await fixture(bots: ["Kai", "Mirrored"])
        f.personal.bots.isHidden = { $0 == made[1].id }
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertEqual(bots.map(\.id), [made[0].id])
        let mirrored = try XCTUnwrap(f.repository.loadConversations().first { $0.participantIDs == [made[1].id] })
        do {
            _ = try await f.device.request(.messages(conversationID: mirrored.id, after: 0))
            XCTFail("another Hub's bot was readable")
        } catch {}
    }

    /// Tools, computers and browsers on the Mac belong to Noodle's own settings; a device does
    /// not make or change them there yet, so none is made where Noodle would not see it.
    func testToolsComputersAndBrowsersAreManagedOnTheMac() async throws {
        let (f, _) = try await fixture(bots: [])
        for request: LinkRequest in [.createBrowser(LinkBrowserDraft(name: "Work")), .deleteComputer(id: UUID()),
                                     .saveConnection(LinkConnectionDraft(name: "Notes", endpoint: URL(string: "https://example.com/mcp")!))] {
            do {
                _ = try await f.device.request(request)
                XCTFail("\(request) was taken")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Manage tools, computers and browsers in Noodle on the Mac.")
            }
        }
    }

    /// It is the owner's own Mac: there is nobody else to add.
    func testNobodyElseCanBeAdded() async throws {
        let (f, _) = try await fixture(bots: [])
        XCTAssertThrowsError(try f.personal.access.addUser(named: "Bob"))
        XCTAssertEqual(f.personal.access.users.count, 1)
    }
}
