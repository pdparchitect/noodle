import AppIntents
import CloudKit
import Foundation
import HubLink
import NoodleWallpaperCore
import Observation
import UIKit
@testable import NoodleMobile
import SwiftUI
import Synchronization
import Testing
import UniformTypeIdentifiers

/// A Hub with one bot that answers every message, reached over QUIC like the real one.
private actor FakeHub {
    var bot = LinkBot(id: UUID(), conversationID: UUID(),
                      draft: LinkBotDraft(name: "Scout", provider: "claude"), createdAt: Date(timeIntervalSince1970: 0))
    var created: [LinkBot] = []
    var groups: [LinkGroup] = []
    /// Files by ID, as uploaded or given to the bot's messages.
    var files: [UUID: (attachment: LinkAttachment, data: Data)] = [:]
    var downloads = 0
    var pictureFetches = 0
    var cardFetches = 0
    var previewFetches = 0
    /// The small picture the Hub makes of a file, as a red square.
    static let preview = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    /// Bot edits as the phone sent them.
    var edits: [LinkBotDraft] = []
    /// Where the phone asked to hear of unread replies, in order.
    var pushTopics: [String?] = []
    var messages: [LinkMessage] = []
    var pageRequests = 0
    /// Where it listens, which it tells the phone when pairing, as the real Hub does.
    var endpoints: [LinkEndpoint] = []

    /// Sends answered with a timeout. When `keepsFailedSends`, the message is taken all the same, as when only the answer is lost.
    var failingSends = 0
    var keepsFailedSends = false

    func listen(at endpoint: LinkEndpoint) { endpoints = [endpoint] }

    /// The live streams phones opened, each told at once that the Hub took it on, as the real Hub does.
    var followers: [LinkStream] = []

    func follow(_ stream: LinkStream) {
        followers.append(stream)
        if holdsFollows { held.append(stream) } else { stream.send(Data()) }
    }

    /// Streams not yet taken on, as by a Hub slow to answer, until `releaseFollows`.
    var holdsFollows = false
    var held: [LinkStream] = []

    func holdFollows() { holdsFollows = true }

    func releaseFollows() {
        holdsFollows = false
        held.forEach { $0.send(Data()) }
        held = []
    }

    func push(_ event: LinkEvent) { followers.last?.send(LinkProtocol.encode(event)) }

    func endStreams() { followers.forEach { $0.close() } }

    /// Conversations whose messages do not load, as on a lossy link.
    var failingConversations: Set<UUID> = []

    func failLoading(_ conversationID: UUID) { failingConversations.insert(conversationID) }

    func failSends(_ count: Int, keeping: Bool = false) {
        failingSends = count
        keepsFailedSends = keeping
    }

    func bodies(saying body: String) -> Int { messages.count { $0.body == body } }

    func setPicture(_ data: Data) { bot.draft.avatarImageData = data }

    func setStatus(_ status: String?) { bot.status = status }
    func takesCalls() { bot.canCall = true }

    /// The small copies of background files the phone asks for, by media name.
    var backgroundFiles: [String: Data] = [:]
    var backgroundFetches = 0
    /// A background's pieces as they arrive.
    var backgroundUpload = Data()

    func setBackground(_ background: LinkBackground, compact: Data? = nil) {
        bot.background = background
        if let media = background.media { backgroundFiles[media] = compact }
    }

    /// A group of Scout, made on another device, with something already said in it.
    func addGroup(named name: String, saying body: String) -> LinkGroup {
        let group = LinkGroup(id: UUID(), draft: LinkGroupDraft(name: name, botIDs: [bot.id]), createdAt: Date(timeIntervalSince1970: 5))
        groups.append(group)
        messages.append(LinkMessage(id: UUID(), conversationID: group.id, author: .bot(bot.id), body: body,
                                    createdAt: Date(timeIntervalSince1970: 30), delivered: true))
        return group
    }

    func data(of id: UUID) -> Data? { files[id]?.data }

    func botSays(_ body: String, in conversationID: UUID) {
        messages.append(LinkMessage(id: UUID(), conversationID: conversationID, author: .bot(bot.id), body: body,
                                    createdAt: Date(), delivered: true))
    }

    func botSays(_ body: String) {
        messages.append(LinkMessage(id: UUID(), conversationID: bot.conversationID, author: .bot(bot.id), body: body,
                                    createdAt: Date(), delivered: true))
    }

    /// A notice the Hub posts itself, such as the bot being back on its first harness.
    func notice(_ body: String) {
        messages.append(LinkMessage(id: UUID(), conversationID: bot.conversationID, author: .system, body: body,
                                    createdAt: Date(), delivered: true))
    }

    /// A noodlet the bot shares, as a link.
    func botSharesNoodlet(_ name: String) -> LinkAttachment {
        let attachment = LinkAttachment(id: UUID(), filename: "\(name).noodlet", mediaType: "application/x-noodlet", byteCount: 0,
                                        url: URL(string: "noodlet://\(UUID().uuidString)"))
        messages.append(LinkMessage(id: UUID(), conversationID: bot.conversationID, author: .bot(bot.id), body: "Play this",
                                    createdAt: Date(), delivered: true, attachments: [attachment]))
        return attachment
    }

    /// A message from the bot carrying a file.
    func botSends(_ data: Data, named filename: String, mediaType: String) -> LinkAttachment {
        let attachment = LinkAttachment(id: UUID(), filename: filename, mediaType: mediaType, byteCount: data.count)
        files[attachment.id] = (attachment, data)
        messages.append(LinkMessage(id: UUID(), conversationID: bot.conversationID, author: .bot(bot.id), body: "Here it is",
                                    createdAt: Date(timeIntervalSince1970: 20), delivered: true, attachments: [attachment]))
        return attachment
    }

    init() {
        messages = [LinkMessage(id: UUID(), conversationID: bot.conversationID, author: .bot(bot.id), body: "Hello",
                                createdAt: Date(timeIntervalSince1970: 10), delivered: true)]
    }

    /// The conversations of the pages asked for since `slowPages`, in order, and how many were asked for at once at most.
    var pageOrder: [UUID] = []
    var pagesInFlight = 0
    var mostPagesInFlight = 0
    /// How long each page takes, as over a slow link.
    var pageDelay: Duration = .zero

    func slowPages(_ delay: Duration) {
        pageDelay = delay
        pageOrder = []
        mostPagesInFlight = 0
    }

    func answer(_ data: Data) async -> LinkResponse {
        guard pageDelay > .zero, case .success(.messagePage(let page)) = LinkProtocol.decode(data) else { return reply(to: data) }
        pageOrder.append(page.conversationID)
        pagesInFlight += 1
        mostPagesInFlight = max(mostPagesInFlight, pagesInFlight)
        try? await Task.sleep(for: pageDelay)
        pagesInFlight -= 1
        return reply(to: data)
    }

    func reply(to data: Data) -> LinkResponse {
        switch LinkProtocol.decode(data) {
        case .success(.enroll):
            return .status(LinkStatus(hubName: "Studio", userName: "Petko", planName: "", harnesses: [], endpoints: endpoints))
        case .success(.bots):
            // As the real Hub answers a device that fetches pictures itself.
            return .bots(([bot] + created).map(\.withoutPicture))
        case .success(.picture(.bot(let id))) where id == bot.id:
            pictureFetches += 1
            return .picture(bot.draft.avatarImageData)
        case .success(.updateBot(let id, let draft)) where id == bot.id:
            edits.append(draft)
            let picture = draft.avatarImageData ?? (draft.avatarImageDigest == nil ? nil : bot.draft.avatarImageData)
            bot.draft = draft
            bot.draft.avatarImageData = picture
            return .bot(bot)
        case .success(.deleteBot(let id)):
            created.removeAll { $0.id == id }
            return .done
        case .success(.groups):
            return .groups(groups)
        case .success(.createGroup(let draft)):
            let group = LinkGroup(id: UUID(), draft: draft, createdAt: Date())
            groups.append(group)
            return .group(group)
        case .success(.updateGroup(let id, let draft)):
            guard let index = groups.firstIndex(where: { $0.id == id }) else { return .failure("No such group.") }
            groups[index].draft = draft
            return .group(groups[index])
        case .success(.deleteGroup(let id)):
            groups.removeAll { $0.id == id }
            return .done
        case .success(.archive(let change)):
            let date: Date? = change.archived ? Date() : nil
            if change.id == bot.id { bot.archivedAt = date }
            else if let index = groups.firstIndex(where: { $0.id == change.id }) { groups[index].archivedAt = date }
            else { return .failure("There is no such bot.") }
            return .done
        case .success(.createBot(let draft)):
            let new = LinkBot(id: UUID(), conversationID: UUID(), draft: draft, createdAt: Date())
            created.append(new)
            return .bot(new)
        case .success(.messages(let conversationID, let after)):
            let messages = messages.filter { $0.conversationID == conversationID }
            return .messages(LinkMessages(messages: Array(messages.dropFirst(after)), count: messages.count))
        case .success(.messagePage(let page)) where failingConversations.contains(page.conversationID):
            return .failure("The Hub did not answer in time.")
        case .success(.messagePage(let page)):
            pageRequests += 1
            let messages = messages.filter { $0.conversationID == page.conversationID }
            if let after = page.after {
                let start = min(after, messages.count)
                return .messages(LinkMessages(messages: Array(messages[start..<min(start + page.limit, messages.count)]),
                                              count: messages.count, start: start))
            }
            let end = min(page.before ?? messages.count, messages.count), start = max(0, end - page.limit)
            return .messages(LinkMessages(messages: Array(messages[start..<end]), count: messages.count, start: start))
        case .success(.pushTopic(let registration)):
            pushTopics.append(registration.topic)
            return .done
        case .success(.markRead(let mark)):
            guard let message = messages.first(where: { $0.id == mark.messageID }) else { return .failure("No such message.") }
            bot.readUpTo = max(bot.readUpTo ?? .distantPast, message.createdAt)
            return .done
        case .success(.react(let change)):
            guard let index = messages.firstIndex(where: { $0.id == change.messageID }) else { return .failure("No such message.") }
            let reaction = LinkReaction(author: .you, emoji: change.emoji)
            messages[index].reactions.removeAll { $0 == reaction }
            if change.present { messages[index].reactions.append(reaction) }
            return .message(messages[index])
        case .success(.upload(_, let attachment, let offset, let data)):
            var file = files[attachment.id] ?? (attachment, Data())
            guard offset == file.data.count else { return .failure("Pieces out of order.") }
            file.data.append(data)
            files[attachment.id] = file
            return .done
        case .success(.download(_, let id, let offset)):
            guard let file = files[id] else { return .failure("No such file.") }
            if offset == 0 { downloads += 1 }
            let end = min(offset + LinkProtocol.chunkSize, file.data.count)
            return .chunk(data: file.data.subdata(in: offset..<end), total: file.data.count)
        case .success(.send) where failingSends > 0 && !keepsFailedSends:
            failingSends -= 1
            return .failure("The Hub did not answer in time.")
        case .success(.send(let outgoing)):
            if messages.contains(where: { $0.id == outgoing.id }) { return .message(messages.first { $0.id == outgoing.id }!) }
            let attachments = outgoing.attachmentIDs.compactMap { files[$0]?.attachment }
            guard attachments.count == outgoing.attachmentIDs.count else { return .failure("A file is missing.") }
            let sent = LinkMessage(id: outgoing.id, conversationID: outgoing.conversationID, author: .you, body: outgoing.body,
                                   createdAt: Date(), delivered: true, attachments: attachments)
            messages.append(sent)
            messages.append(LinkMessage(id: UUID(), conversationID: outgoing.conversationID, author: .bot(bot.id),
                                        body: "You said: \(outgoing.body)", createdAt: Date(), delivered: true))
            if failingSends > 0 {
                failingSends -= 1
                return .failure("The Hub did not answer in time.")
            }
            return .message(sent)
        case .success(.setBackground(let choice)) where choice.conversationID == bot.conversationID:
            bot.background = LinkBackground(preset: choice.preset)
            return .background(bot.background!)
        case .success(.uploadBackground(let piece)) where piece.conversationID == bot.conversationID:
            if piece.offset == 0 { backgroundUpload = Data() }
            guard piece.offset == backgroundUpload.count else { return .failure("Pieces out of order.") }
            backgroundUpload.append(piece.data)
            guard backgroundUpload.count == piece.byteCount else { return .done }
            setBackground(LinkBackground(media: "\(UUID()).jpg", mediaKind: "image"), compact: backgroundUpload)
            return .background(bot.background!)
        case .success(.backgroundMedia(let fetch)) where fetch.conversationID == bot.conversationID && fetch.compact:
            guard fetch.media == bot.background?.media, let data = backgroundFiles[fetch.media] else { return .failure("No such background.") }
            if fetch.offset == 0 { backgroundFetches += 1 }
            let end = min(fetch.offset + LinkProtocol.chunkSize, data.count)
            return .chunk(data: data.subdata(in: fetch.offset..<end), total: data.count)
        case .success(.kick(let id)) where id == bot.id:
            restarts.append("kick")
            return kickConfirmation.map(LinkResponse.kickConfirmation) ?? .done
        case .success(.confirmKick(let id, let confirmationID)) where id == bot.id:
            restarts.append("confirm \(confirmationID)")
            return .done
        case .success(.newSession(let id)) where id == bot.id:
            restarts.append("new session")
            return .done
        case .success(.organize(let id)) where id == bot.id:
            restarts.append("organize")
            return .done
        case .success(.pin(let pin)) where pin.conversationID == bot.conversationID:
            bot.pinnedAt = pin.pinned ? Date() : nil
            pins.append(pin)
            return .done
        case .success(.takeEffect(let id)) where id == bot.conversationID:
            defer { effect = nil }
            takes += 1
            return .effect(effect)
        case .success(.hubSharing(let id)) where id == bot.id:
            return .hubSharing(hubSharing)
        case .success(.shareOnHub(let id, let hub, let people)) where id == bot.id:
            guard let index = hubSharing.firstIndex(where: { $0.id == hub }) else { return .failure("No such Hub.") }
            hubSharing[index].sharedWith = people
            return .hubSharing(hubSharing)
        case .success(.computers):
            return .computers(computers)
        case .success(.browsers):
            return .browsers(browsers)
        case .success(.updateComputer(let id, let draft)):
            guard let index = computers.firstIndex(where: { $0.id == id }) else { return .failure("No such computer.") }
            computers[index].name = draft.name
            // As the Hub's apps do: no description keeps the one it has, and an empty one clears it.
            if let description = draft.description { computers[index].description = description.isEmpty ? nil : description }
            return .computer(computers[index])
        case .success(.updateBrowser(let id, let draft)):
            guard let index = browsers.firstIndex(where: { $0.id == id }) else { return .failure("No such browser.") }
            browsers[index].name = draft.name
            if let description = draft.description { browsers[index].description = description.isEmpty ? nil : description }
            return .browser(browsers[index])
        case .success(.deleteComputer(let id)):
            computers.removeAll { $0.id == id }
            return .done
        case .success(.deleteBrowser(let id)):
            browsers.removeAll { $0.id == id }
            return .done
        case .success(.linkCard):
            cardFetches += 1
            return .linkCard(LinkCardInfo(title: "Racer"))
        case .success(.linkPreview):
            return .picture(Data("racer picture".utf8))
        case .success(.attachmentPreview(_, let id, _)):
            guard files[id] != nil else { return .failure("No such file.") }
            previewFetches += 1
            return .picture(Self.preview)
        default:
            return .failure("Not in this test.")
        }
    }

    /// The chat effect waiting in Scout's conversation, taken once, and how often the phone asked.
    var effect: LinkEffect?
    var takes = 0

    func setEffect(_ effect: LinkEffect?) { self.effect = effect }

    /// As the owner's Mac answers: the Hubs it joined, whose people its bot can be shared with.
    var hubSharing: [LinkHubSharing] = []

    func setHubSharing(_ sharing: [LinkHubSharing]) { hubSharing = sharing }

    /// Pins as the phone sent them.
    var pins: [LinkPin] = []
    /// Kick, confirmations and new sessions, as the phone asked for them.
    var restarts: [String] = []
    /// What Kick asks first, or nil to restart at once.
    var kickConfirmation: LinkKickConfirmation?

    func askBeforeKick(_ confirmation: LinkKickConfirmation?) { kickConfirmation = confirmation }

    /// This user's computers and browsers on the Hub.
    var computers: [LinkComputer] = []
    var browsers: [LinkBrowser] = []

    func keep(_ computer: LinkComputer, _ browser: LinkBrowser) {
        computers.append(computer)
        browsers.append(browser)
    }
}

/// Whether the Hub lets the phone in, switched by a test from any thread.
private final class Door: Sendable {
    private let open = Mutex(true)
    var isOpen: Bool { open.withLock { $0 } }
    func set(open: Bool) { self.open.withLock { $0 = open } }
}

/// Whether something happened, set from any thread.
private final class Flag: Sendable {
    private let raised = Mutex(false)
    var isRaised: Bool { raised.withLock { $0 } }
    func raise() { raised.withLock { $0 = true } }
}

/// Whether a view that read what `read` reads would be drawn again after `change`.
@MainActor private func redraws(_ read: () -> Void, after change: () async throws -> Void) async rethrows -> Bool {
    let changed = Flag()
    withObservationTracking(read) { changed.raise() }
    try await change()
    return changed.isRaised
}

/// The pauses `follow` took before trying again.
private final class Pauses: Sendable {
    private let taken = Mutex<[Duration]>([])
    var all: [Duration] { taken.withLock { $0 } }
    func take(_ pause: Duration) { taken.withLock { $0.append(pause) } }
}

/// Stands in for CloudKit, keeping the topics subscribed to.
private actor RecordedSubscriptions: PushSubscriptions {
    var topics: Set<String> = []
    var failing = false

    func fail() { failing = true }

    func subscribe(topic: String) throws {
        if failing { throw LinkError("Not signed in to iCloud.") }
        topics.insert(topic)
    }

    func unsubscribe(topic: String) { topics.remove(topic) }
}

@MainActor @Suite struct HubChatsTests {
    private func paired(to hub: FakeHub, directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString),
                        admits: @escaping @Sendable (LinkPublicKey) -> Bool = { _ in true }) async throws -> (HubChats, LinkServer) {
        let identity = LinkIdentity()
        let server = try LinkServer(identity: identity, port: 0, admits: admits) { _, data in
            if case .success(.subscribe) = LinkProtocol.decode(data) { return .stream { stream in Task { await hub.follow(stream) } } }
            return .response(LinkProtocol.encode(await hub.answer(data)))
        }
        try await server.start()
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: try #require(server.port))
        await hub.listen(at: endpoint)
        let invitation = LinkInvitation(hubName: "Studio", hubKey: identity.publicKey, endpoints: [endpoint],
                                        userName: "Petko", joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date().addingTimeInterval(600))
        let pairing = HubPairing(directory: directory, deviceName: "iPhone")
        await pairing.join(invitation.url().absoluteString)
        try #require(pairing.hub != nil)
        return (HubChats(pairing: pairing), server)
    }

    /// The live stream opens even when a conversation does not load, as on a lossy link: the rest
    /// still load, the failure is kept, and what the Hub pushes arrives.
    @Test func followingOpensTheLiveStreamWhenAConversationDoesNotLoad() async throws {
        let hub = FakeHub()
        let crew = await hub.addGroup(named: "Crew", saying: "Morning")
        let scout = await hub.bot
        await hub.failLoading(scout.conversationID)
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let following = Task { await chats.follow() }
        defer { following.cancel() }
        for _ in 0..<100 where !chats.isConnected || chats.error == nil || chats.messages(of: crew).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(chats.isConnected)
        #expect(await hub.followers.count == 1)
        #expect(chats.agents.map(\.id) == [scout.id])
        #expect(chats.messages(of: crew).map(\.body) == ["Morning"])
        #expect(chats.error == "The Hub did not answer in time.")

        await hub.push(.botPhase(botID: scout.id, phase: .working))
        for _ in 0..<50 where chats.agent(scout.id)?.phase != .working { try await Task.sleep(for: .milliseconds(100)) }
        #expect(chats.agent(scout.id)?.phase == .working)
    }

    /// Each failure waits longer before trying again, up to half a minute; once the Hub answers
    /// again, the next wait starts over from a second.
    @Test func reconnectingWaitsLongerEachTimeAndStartsOverOnceConnected() async throws {
        let hub = FakeHub()
        let door = Door()
        let (phone, server) = try await paired(to: hub, admits: { _ in door.isOpen })
        defer { server.stop() }
        let pauses = Pauses()
        let chats = HubChats(pairing: phone.pairing, networkChanges: { AsyncStream { _ in } },
                             pause: { pause in
                                 pauses.take(pause)
                                 try await Task.sleep(for: .milliseconds(20))
                             },
                             backoff: HubBackoff(jitter: { 1 }))
        door.set(open: false)
        let following = Task { await chats.follow() }
        defer { following.cancel() }
        for _ in 0..<100 where pauses.all.count < 6 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(Array(pauses.all.prefix(6)) == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)])
        #expect(chats.connectionProblem != nil)
        #expect(!chats.isConnected)

        door.set(open: true)
        for _ in 0..<100 where !chats.isConnected { try await Task.sleep(for: .milliseconds(100)) }
        #expect(chats.isConnected)
        #expect(chats.connectionProblem == nil)
        let connected = pauses.all.count
        await hub.endStreams()
        for _ in 0..<100 where pauses.all.count == connected { try await Task.sleep(for: .milliseconds(100)) }
        #expect(pauses.all.dropFirst(connected).first == .seconds(1))
    }

    /// A change of network, as on joining Wi-Fi, connects at once instead of waiting out the pause.
    @Test func aNetworkChangeConnectsAtOnce() async throws {
        let hub = FakeHub()
        let door = Door()
        let (phone, server) = try await paired(to: hub, admits: { _ in door.isOpen })
        defer { server.stop() }
        let pauses = Pauses()
        let (changes, change) = AsyncStream.makeStream(of: Void.self)
        let chats = HubChats(pairing: phone.pairing, networkChanges: { changes }, pause: { pause in
            pauses.take(pause)
            try await Task.sleep(for: .seconds(3600))
        })
        door.set(open: false)
        let following = Task { await chats.follow() }
        defer { following.cancel() }
        for _ in 0..<100 where pauses.all.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(pauses.all.count == 1)

        door.set(open: true)
        change.yield()
        for _ in 0..<100 where !chats.isConnected { try await Task.sleep(for: .milliseconds(100)) }
        #expect(chats.isConnected)
        #expect(pauses.all.count == 1, "Connected without waiting out the pause")
    }

    /// Try Again connects at once too.
    @Test func tryAgainConnectsAtOnce() async throws {
        let hub = FakeHub()
        let door = Door()
        let (phone, server) = try await paired(to: hub, admits: { _ in door.isOpen })
        defer { server.stop() }
        let pauses = Pauses()
        let chats = HubChats(pairing: phone.pairing, networkChanges: { AsyncStream { _ in } }, pause: { pause in
            pauses.take(pause)
            try await Task.sleep(for: .seconds(3600))
        })
        door.set(open: false)
        let following = Task { await chats.follow() }
        defer { following.cancel() }
        for _ in 0..<100 where pauses.all.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(chats.connectionProblem != nil)

        door.set(open: true)
        chats.tryAgain()
        for _ in 0..<100 where !chats.isConnected { try await Task.sleep(for: .milliseconds(100)) }
        #expect(chats.isConnected)
        #expect(pauses.all.count == 1)
    }

    /// The app coming back to the front starts connecting, and then becomes active: that leaves the connection under
    /// way to finish, rather than dropping it and waiting before starting over.
    @Test func comingBackLeavesAConnectionUnderWayToFinish() async throws {
        let hub = FakeHub()
        let (phone, server) = try await paired(to: hub)
        defer { server.stop() }
        let pauses = Pauses()
        let chats = HubChats(pairing: phone.pairing, networkChanges: { AsyncStream { _ in } }, pause: { pause in
            pauses.take(pause)
            try await Task.sleep(for: .seconds(3600))
        })
        await hub.holdFollows()
        let following = Task { await chats.follow() }
        defer { following.cancel() }
        for _ in 0..<100 where await hub.followers.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(chats.isConnecting)

        chats.resume()
        await hub.releaseFollows()
        for _ in 0..<100 where !chats.isConnected && pauses.all.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(chats.isConnected)
        #expect(pauses.all.isEmpty)
        #expect(await hub.followers.count == 1)
    }

    /// A chat effect waits on the Hub until the phone shows its conversation: the phone hears of it, takes it
    /// once, and asks no more until it hears of another.
    @Test func aChatEffectIsTakenOnceWhenItsConversationIsShown() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let scout = await hub.bot
        #expect(!chats.hasWaitingEffect(in: scout.conversationID))
        let confetti = LinkEffect(id: UUID(), kind: "confetti")
        await hub.setEffect(confetti)
        try await chats.apply(.effectWaiting(conversationID: scout.conversationID))
        #expect(chats.hasWaitingEffect(in: scout.conversationID))
        #expect(await chats.takeEffect(in: scout.conversationID) == confetti)
        #expect(await chats.takeEffect(in: scout.conversationID) == nil)
        #expect(await hub.takes == 1, "Not asked again until another is heard of")
    }

    /// Nothing is taken while the app is in the background, so the effect still waits; one this phone cannot draw is
    /// taken all the same, so it does not wait for ever, and plays nothing.
    @Test func aChatEffectPlaysOnlyWithTheAppInFrontAndOnlyIfThePhoneDrawsIt() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let scout = await hub.bot
        let fireworks = LinkEffect(id: UUID(), kind: "fireworks")
        await hub.setEffect(fireworks)
        try await chats.apply(.effectWaiting(conversationID: scout.conversationID))
        #expect(await chats.effectToPlay(in: scout.conversationID, appInFront: false) == nil)
        #expect(chats.hasWaitingEffect(in: scout.conversationID), "Still waiting")
        #expect(await hub.takes == 0)
        let played = await chats.effectToPlay(in: scout.conversationID, appInFront: true)
        #expect(played?.effect == .fireworks)
        #expect(played?.id == fireworks.id)

        await hub.setEffect(LinkEffect(id: UUID(), kind: "future-kind"))
        try await chats.apply(.effectWaiting(conversationID: scout.conversationID))
        #expect(await chats.effectToPlay(in: scout.conversationID, appInFront: true) == nil)
        #expect(!chats.hasWaitingEffect(in: scout.conversationID))
        #expect(await hub.takes == 2)
    }

    /// On the owner's own Mac, a bot there is shared through the Hubs the Mac joined, one at a time, a person at a time.
    @Test func aBotOnTheOwnersMacIsSharedThroughTheHubsItJoined() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let scout = await hub.bot, grace = LinkPerson(id: UUID(), name: "Grace"), bea = LinkPerson(id: UUID(), name: "Bea")
        #expect(await chats.hubSharing(scout) == [])
        await hub.setHubSharing([LinkHubSharing(id: "studio", name: "Studio", people: [grace, bea], sharedWith: [bea.id]),
                                 LinkHubSharing(id: "office", name: "Office", people: [grace], sharedWith: [])])
        let listed = await chats.hubSharing(scout)
        #expect(listed.map(\.name) == ["Studio", "Office"])
        let shared = try await chats.toggleSharing(scout, with: grace.id, on: try #require(listed.first))
        #expect(Set(shared.first { $0.id == "studio" }?.sharedWith ?? []) == [bea.id, grace.id])
        #expect(shared.first { $0.id == "office" }?.sharedWith == [])
        let unshared = try await chats.toggleSharing(scout, with: bea.id, on: try #require(shared.first { $0.id == "studio" }))
        #expect(unshared.first { $0.id == "studio" }?.sharedWith == [grace.id])
    }

    /// Kick restarts at once or brings back the Hub's question, whose answer names it; New Session and Organize go straight through.
    @Test func kickAndNewSessionReachTheHub() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let scout = await hub.bot

        #expect(try await chats.kick(scout) == nil)
        let question = LinkKickConfirmation(id: UUID(), title: "Safeguards stopped Scout", message: "Stopped.",
                                            confirmTitle: "Resume", offersNewSession: true)
        await hub.askBeforeKick(question)
        let asked = try #require(try await chats.kick(scout))
        #expect(asked == question)
        try await chats.confirmKick(asked, for: scout)
        try await chats.startNewSession(scout)
        try await chats.organize(scout)
        #expect(await hub.restarts == ["kick", "kick", "confirm \(question.id)", "new session", "organize"])
    }

    /// A long conversation opens on its newest page; scrolling back brings the rest.
    @Test func aLongConversationOpensOnItsNewestPage() async throws {
        let hub = FakeHub()
        for index in 1..<120 { await hub.botSays("Message \(index)") }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.reload()
        let scout = try #require(chats.agents.first)
        #expect(chats.messages(of: scout).count == 50)
        #expect(chats.messages(of: scout).last?.body == "Message 119")
        #expect(chats.hasEarlier(scout))
        while chats.hasEarlier(scout) { try await chats.loadEarlier(scout) }
        #expect(chats.messages(of: scout).map(\.body) == ["Hello"] + (1..<120).map { "Message \($0)" })
    }

    /// The console finds a noodlet shared long before the newest page, and looks through that history once.
    @Test func theConsoleFindsNoodletsSharedLongAgoOnce() async throws {
        let hub = FakeHub()
        let racer = await hub.botSharesNoodlet("Racer")
        for index in 1..<120 { await hub.botSays("Message \(index)") }
        let recent = await hub.botSharesNoodlet("Notes")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()

        let console = Console()
        console.show([chats])
        #expect(console.titles.map(\.attachment.id) == [recent.id])
        await console.scan()
        #expect(console.titles.map(\.attachment.id) == [recent.id, racer.id])

        // Again, even after a relaunch, nothing already looked through is asked for.
        let asked = await hub.pageRequests
        let again = Console()
        again.show([chats])
        await again.scan()
        #expect(await hub.pageRequests == asked)
        #expect(again.titles.map(\.attachment.id) == [recent.id, racer.id])
    }

    /// A message sent before the conversation has loaded still lands after what was already said.
    @Test func messagesKeepTheirOrderWhenSentBeforeTheConversationLoads() async throws {
        let hub = FakeHub()
        await hub.botSays("Earlier")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.send("Hi", to: await hub.bot)
        let bodies = chats.messages(of: await hub.bot).map(\.body)
        #expect(Array(bodies.prefix(3)) == ["Hello", "Earlier", "Hi"])
    }

    /// A bot's picture is fetched once, apart from the list, and an edit does not send it back.
    @Test func botPicturesAreFetchedOnceAndNotSentBack() async throws {
        let hub = FakeHub()
        let picture = Data(repeating: 5, count: 2_000_000)
        await hub.setPicture(picture)
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.reload()
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        #expect(scout.draft.avatarImageData == picture)
        #expect(await hub.pictureFetches == 1)

        var renamed = scout
        renamed.draft.name = "Ranger"
        try await chats.update(renamed)
        #expect(await hub.edits.last?.avatarImageData == nil)
        #expect(await hub.bot.draft.avatarImageData == picture)
        #expect(await hub.bot.draft.name == "Ranger")
    }

    /// Computers and browsers on the Hub are renamed and described from the phone, an empty description
    /// clears one, and deleting one first says which bots lose it.
    @Test func computersAndBrowsersAreEditedFromThePhone() async throws {
        let hub = FakeHub()
        let scout = await hub.bot
        let computer = LinkComputer(id: UUID(), name: "Workbench", kind: "Linux", state: "Stopped", symbol: "terminal", botIDs: [scout.id])
        let browser = LinkBrowser(id: UUID(), name: "Work", description: "Sign-ins")
        await hub.keep(computer, browser)
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        try await chats.loadComputers()
        try await chats.loadBrowsers()

        try await chats.updateComputer(computer, name: "Bench", description: "For builds")
        #expect(chats.computers.map(\.name) == ["Bench"])
        #expect(chats.computers.first?.description == "For builds")
        try await chats.updateBrowser(browser, name: "Office", description: "")
        #expect(chats.browsers.map(\.name) == ["Office"])
        #expect(chats.browsers.first?.description == nil)

        #expect(chats.deletionSummary(.computer, computer.id) == "It moves to the Trash on the Hub, and Scout loses it.")
        #expect(chats.deletionSummary(.browser, browser.id) == "Its sign-ins and history are erased for good.")
        try await chats.deleteBrowser(try #require(chats.browsers.first))
        #expect(chats.browsers.isEmpty)
        #expect(await hub.computers.map(\.name) == ["Bench"])
    }

    @Test func agentsListWithTheirLatestMessage() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.reload()

        #expect(chats.agents.map(\.draft.name) == ["Scout"])
        #expect(chats.latestMessage(of: try #require(chats.agents.first))?.body == "Hello")
    }

    @Test func sendingShowsMyMessageAndTheReply() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        try await chats.send("Hi there", to: scout)

        #expect(chats.messages(of: scout).map(\.body) == ["Hello", "Hi there", "You said: Hi there"])
        #expect(chats.messages(of: scout)[1].author == .you)
    }

    @Test func aNewAgentIsMadeOnTheHubAndListed() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()

        let agent = try await chats.create(LinkBotDraft(name: "Atlas", provider: "codex"))

        #expect(agent.draft.name == "Atlas")
        #expect(chats.agents.map(\.draft.name).contains("Atlas"))
        #expect(await hub.created.map(\.draft.provider) == ["codex"])
    }

    @Test func pinnedAgentsComeFirstAndStayPinned() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        // A newer agent with no messages sorts above Scout, whose only message is from 1970.
        let atlas = try await chats.create(LinkBotDraft(name: "Atlas", provider: "codex"))
        #expect(chats.sortedThreads.map(\.id) == [atlas.id, scout.id])

        chats.togglePin(scout)

        #expect(chats.isPinned(scout))
        #expect(chats.sortedThreads.map(\.id) == [scout.id, atlas.id])
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.isPinned(scout))
    }

    /// In a Hub's own space pins are the Hub's, shared with the user's other devices; All keeps this phone's own.
    @Test func pinsInAHubsSpaceAreKeptOnTheHub() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        try await chats.toggleHubPin(scout)

        #expect(chats.isPinned(scout, onHub: true))
        #expect(!chats.isPinned(scout))
        #expect(await hub.pins == [LinkPin(conversationID: scout.conversationID, pinned: true)])
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.isPinned(scout, onHub: true))
        // Unpinned on another device.
        try await chats.apply(.pinChanged(conversationID: scout.conversationID, pinnedAt: nil))
        #expect(!chats.isPinned(scout, onHub: true))
    }

    /// A Hub's pins keep the order they were pinned in, as on the Mac, however recent their conversations.
    @Test func pinsInAHubsSpaceKeepTheirOrder() async throws {
        let (chats, server) = try await paired(to: FakeHub())
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let atlas = try await chats.create(LinkBotDraft(name: "Atlas", provider: "codex"))
        try await chats.apply(.pinChanged(conversationID: atlas.conversationID, pinnedAt: Date(timeIntervalSinceReferenceDate: 2)))
        try await chats.apply(.pinChanged(conversationID: scout.conversationID, pinnedAt: Date(timeIntervalSinceReferenceDate: 1)))

        let threads = chats.listedThreads.map { (chats, $0) }
        #expect(HubChats.sorted(threads, onHub: true).map(\.1.id) == [scout.id, atlas.id])
    }

    /// A space the person made holds only its members, named by their Hub and conversation there as on the Mac,
    /// with its own pins first in the order they were pinned.
    @Test func aCustomSpaceShowsItsMembersWithItsPins() async throws {
        let (chats, server) = try await paired(to: FakeHub())
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let atlas = try await chats.create(LinkBotDraft(name: "Atlas", provider: "codex"))
        _ = try await chats.create(LinkBotDraft(name: "Nova", provider: "codex"))
        let member = chats.spaceMember(of: atlas)
        #expect(member == CustomSpace.Member(hub: chats.pairing.hub?.key.x963.base64EncodedString(), conversation: atlas.conversationID))
        let space = CustomSpace(name: "Work", members: [chats.spaceMember(of: scout), member,
                                                        CustomSpace.Member(hub: "left", conversation: UUID())],
                                pins: [chats.spaceMember(of: scout)])

        // Scout is older than Atlas, but pinned.
        #expect(HubChats.threads(in: space, of: [chats]).map(\.1.id) == [scout.id, atlas.id])
        #expect(!chats.isPinned(scout))
    }

    /// The widgets offer each space's bots as the list orders them, with the Hub's pins in its space and a space's own
    /// in one the person made. Groups are left out. A widget's bot opens on its Hub, named by its key.
    @Test func widgetsListTheBotsOfEachSpace() async throws {
        let hub = FakeHub()
        _ = await hub.addGroup(named: "House", saying: "Hi all")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let atlas = try await chats.create(LinkBotDraft(name: "Atlas", provider: "codex"))
        try await chats.apply(.pinChanged(conversationID: scout.conversationID, pinnedAt: Date()))
        let work = CustomSpace(name: "Work", members: [chats.spaceMember(of: scout), chats.spaceMember(of: atlas)],
                               pins: [chats.spaceMember(of: atlas)])

        let source = BotWidgetPublisher.source(chats: [chats], spaces: [work])

        let key = CurrentHub.space(of: chats.pairing)
        let id = { (bot: LinkBot) in WidgetBot.id(hub: key, conversationID: bot.conversationID) }
        // In All the Hub's pins are not this phone's, so the newest comes first.
        #expect(source.bots.map(\.id) == [id(atlas), id(scout)])
        #expect(source.bots.map(\.face.name) == ["Atlas", "Scout"])
        #expect(source.bots.allSatisfy { $0.hubName == "Studio" })
        #expect(source.spaces == [WidgetSpace(id: key, name: "Studio", bots: [id(scout), id(atlas)]),
                                  WidgetSpace(id: work.id.uuidString, name: "Work", bots: [id(atlas), id(scout)])])

        let route = CurrentHub.route(to: WidgetLink(hub: key, conversationID: atlas.conversationID), in: [chats.pairing])
        #expect(route == NotificationRoute(topic: PushTopic.topic(for: chats.pairing), conversation: atlas.conversationID))
        #expect(CurrentHub.route(to: WidgetLink(hub: "left", conversationID: atlas.conversationID), in: [chats.pairing]) == nil)
    }

    /// Edit Spaces' delete only asks about the space swiped or tapped; nothing is deleted until the person confirms.
    @Test func deletingASpaceAsksAboutIt() {
        let (work, home) = (CustomSpace(name: "Work"), CustomSpace(name: "Home"))
        #expect(SpaceEditor.asked(IndexSet(integer: 1), in: [work, home]) == home)
        #expect(SpaceEditor.asked(IndexSet(integer: 2), in: [work, home]) == nil)
        #expect(SpaceEditor.asked([], in: [work, home]) == nil)
    }

    /// The title menu ticks All once the chosen space is gone: deleted on another device, or its Hub left.
    @Test func aSpaceGoneLeavesAllTicked() {
        let work = CustomSpace(name: "Work")
        #expect(AgentsView.tickedSpace(work.id.uuidString, hubs: ["studio"], spaces: [work]) == work.id.uuidString)
        #expect(AgentsView.tickedSpace("studio", hubs: ["studio"], spaces: []) == "studio")
        #expect(AgentsView.tickedSpace(work.id.uuidString, hubs: ["studio"], spaces: []) == "")
        #expect(AgentsView.tickedSpace("left", hubs: ["studio"], spaces: [work]) == "")
    }

    /// Group Info lists the group's bots first, so one can be removed without hunting, then those in the space shown,
    /// then the rest, each by name; All, or the group's own Hub's space, holds every bot and adds no tier.
    @Test func groupMembersListMembersThenSpaceThenTheRest() {
        func bot(_ name: String) -> LinkBot {
            LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: name, provider: "claude"),
                    createdAt: Date(timeIntervalSince1970: 0))
        }
        let (atlas, nova, scout, zed) = (bot("Atlas"), bot("Nova"), bot("Scout"), bot("Zed"))
        let bots = [zed, scout, nova, atlas]
        let work = CustomSpace(name: "Work", members: [CustomSpace.Member(hub: "studio", conversation: scout.conversationID),
                                                      CustomSpace.Member(hub: "other", conversation: nova.conversationID)])
        func order(_ space: String, members: [LinkBot]) -> [String] {
            let inSpace = GroupEditor.inSpace(space, hub: "studio", spaces: [work])
            return GroupEditor.ordered(bots, members: Set(members.map(\.id)), inSpace: inSpace).map(\.draft.name)
        }

        #expect(order(work.id.uuidString, members: [zed]) == ["Zed", "Scout", "Atlas", "Nova"])
        #expect(order(work.id.uuidString, members: [scout, zed]) == ["Scout", "Zed", "Atlas", "Nova"])
        #expect(order("", members: [zed]) == ["Zed", "Atlas", "Nova", "Scout"])
        #expect(order("studio", members: [nova]) == ["Nova", "Atlas", "Scout", "Zed"])
        #expect(order("other", members: []) == ["Atlas", "Nova", "Scout", "Zed"])
    }

    /// As in the Mac sidebar: by name, description or what was said, ignoring case and accents.
    @Test func searchFindsAgentsByNameDescriptionAndMessages() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        var draft = LinkBotDraft(name: "Zoë", provider: "codex")
        draft.publicDescription = "Keeps the garden"
        let zoe = try await chats.create(draft)
        let cases: [(String, [UUID])] = [
            ("zoe", [zoe.id]), ("SCOUT", [scout.id]), ("  garden ", [zoe.id]), ("hello", [scout.id]),
            ("nobody", []), (" \n ", [zoe.id, scout.id])
        ]
        for (query, expected) in cases {
            #expect(chats.sortedThreads.filter { chats.matches($0, search: query) }.map(\.id) == expected, "\(query)")
        }
    }

    @Test func anEditedAgentShowsItsNewDetails() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        var scout = try #require(chats.agents.first)
        scout.draft.name = "Scout II"

        try await chats.update(scout)

        #expect(chats.agents.map(\.draft.name) == ["Scout II"])
        #expect(await hub.bot.draft.name == "Scout II")
    }

    /// Ticked among a bot's tools, Image Generation applies at once, as the other tools do, and leaves
    /// the rest of the bot as the Hub has it.
    @Test func imageGenerationIsTickedAmongTheToolsAtOnce() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        var scout = try #require(chats.agents.first)
        scout.draft.name = "Unsaved"

        try await chats.setImageGeneration(true, for: scout)

        #expect(await hub.bot.draft.imageGeneration)
        #expect(await hub.bot.draft.name == "Scout")
        #expect(chats.agents.first?.draft.imageGeneration == true)
        try await chats.setImageGeneration(false, for: scout)
        #expect(await hub.bot.draft.imageGeneration == false)
    }

    @Test func aRelaunchShowsWhatWasLastSyncedBeforeTheHubAnswers() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        try await chats.reload()
        #expect(chats.isLoaded)
        server.stop()

        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))

        let scout = try #require(relaunched.agents.first)
        #expect(scout.draft.name == "Scout")
        #expect(relaunched.latestMessage(of: scout)?.body == "Hello")
    }

    /// The phone keeps each conversation's latest messages for the next launch, not all it ever loaded; earlier ones
    /// load again as the person scrolls back.
    @Test func aRelaunchKeepsTheLatestMessagesOfALongConversation() async throws {
        let hub = FakeHub()
        for index in 1..<260 { await hub.botSays("Message \(index)") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        while chats.hasEarlier(scout) { try await chats.loadEarlier(scout) }
        #expect(chats.messages(of: scout).count == 260)

        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.messages(of: scout).count == 200)
        #expect(relaunched.messages(of: scout).first?.body == "Message 60")
        #expect(relaunched.latestMessage(of: scout)?.body == "Message 259")
        #expect(relaunched.hasEarlier(scout))
        try await relaunched.loadEarlier(scout)
        #expect(relaunched.messages(of: scout).first?.body == "Message 10")
    }

    /// A burst of changes, as when the app comes back, is written once, a moment later and off the main thread; reading
    /// the file never misses the latest.
    @Test func theLastSyncIsWrittenOnceForABurstOfChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = ChatsCacheFile.at(url)
        for name in ["Scout", "Atlas", "Nova"] {
            let bot = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: name, provider: "claude"), createdAt: Date())
            file.save(ChatsCache(agents: [bot], conversations: [:], read: [:]))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(ChatsCacheFile.at(url) === file)
        #expect(file.load()?.agents.map(\.draft.name) == ["Nova"])
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func noAgentsIsOnlyKnownOnceTheHubHasAnswered() {
        let chats = HubChats(pairing: HubPairing(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), deviceName: "iPhone"))
        #expect(chats.agents.isEmpty)
        #expect(!chats.isLoaded)
    }

    /// A draft of nothing but blank lines or spaces is not kept, so the field comes back empty, at its usual size.
    @Test func aBlankDraftIsNotKept() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        try FileManager.default.createDirectory(at: chats.pairing.directory, withIntermediateDirectories: true)
        let scout = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Scout", provider: "claude"),
                            createdAt: Date(timeIntervalSince1970: 0))
        let atlas = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Atlas", provider: "codex"),
                            createdAt: Date(timeIntervalSince1970: 0))
        chats.setDraft("Hello\n", for: scout)
        chats.setDraft("\n", for: scout)
        #expect(chats.draft(for: scout) == "")
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).draft(for: scout) == "")

        // One saved before blank drafts were dropped comes back empty too.
        try JSONEncoder().encode([atlas.conversationID: " \n "])
            .write(to: chats.pairing.directory.appendingPathComponent("drafts.json"), options: .atomic)
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).draft(for: atlas) == "")
    }

    @Test func aDeletedBotLeavesTheListThePinsAndTheSavedCopy() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let atlas = try await chats.create(LinkBotDraft(name: "Atlas", provider: "codex"))
        chats.togglePin(atlas)

        try await chats.delete(atlas)

        #expect(!chats.agents.contains { $0.id == atlas.id })
        #expect(!chats.isPinned(atlas))
        #expect(await hub.created.isEmpty)
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(!relaunched.agents.contains { $0.id == atlas.id })
        #expect(!relaunched.isPinned(atlas))
    }

    @Test func anArchivedBotOrGroupLeavesTheListUntilUnarchived() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        let house = await hub.addGroup(named: "House", saying: "Dinner at eight.")
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        try await chats.setArchived(true, .bot(scout))
        #expect(await hub.bot.archivedAt != nil)
        #expect(chats.isArchived(.bot(try #require(chats.agent(scout.id)))))
        #expect(chats.listedThreads.map(\.id) == [house.id])
        #expect(chats.archivedThreads.map(\.id) == [scout.id])
        #expect(chats.composerUnavailableReason(for: .bot(try #require(chats.agent(scout.id)))) == "Scout is archived")
        #expect(chats.composerUnavailableReason(for: .group(house)) == "Every bot in this group is archived")
        #expect(chats.activeMembers(of: house).isEmpty)
        // Kept across a relaunch, before the Hub answers.
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.archivedThreads.map(\.id) == [scout.id])

        try await chats.setArchived(false, .bot(try #require(chats.agent(scout.id))))
        #expect(await hub.bot.archivedAt == nil)
        #expect(Set(chats.listedThreads.map(\.id)) == [scout.id, house.id])

        try await chats.setArchived(true, .group(house))
        #expect(chats.listedThreads.map(\.id) == [scout.id])
        #expect(chats.composerUnavailableReason(for: .group(try #require(chats.groups.first))) == "This group is archived")
        try await chats.reload()
        #expect(chats.archivedThreads.map(\.id) == [house.id])
        try await chats.setArchived(false, .group(try #require(chats.groups.first)))
        #expect(chats.archivedThreads.isEmpty)
    }

    @Test func sentFilesReachTheHubWithTheMessage() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        // Bigger than one piece, so it travels in several.
        let data = Data((0..<(LinkProtocol.chunkSize + 1000)).map { UInt8($0 % 251) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try data.write(to: file)

        try await chats.send("Look", files: [OutgoingFile(url: file, filename: "photo.png", mediaType: "image/png")], to: scout)

        let sent = try #require(chats.messages(of: scout).first { $0.body == "Look" })
        let attachment = try #require(sent.attachments.first)
        #expect(attachment.filename == "photo.png")
        #expect(await hub.data(of: attachment.id) == data)
        // The phone keeps what it sent, so it never downloads it back.
        #expect(try Data(contentsOf: try await chats.file(for: attachment, in: scout)) == data)
        #expect(await hub.downloads == 0)
    }

    /// Forward… sends a bot's file on to a group as one message of yours, with the comment as its words. The file
    /// goes up again under an ID of its own, since the Hub keeps each conversation's files apart.
    @Test func aForwardedFileReachesTheGroupWithTheComment() async throws {
        let hub = FakeHub()
        let data = Data((0..<(LinkProtocol.chunkSize + 1000)).map { UInt8($0 % 251) })
        let original = await hub.botSends(data, named: "report.pdf", mediaType: "application/pdf")
        let crew = await hub.addGroup(named: "Crew", saying: "Morning")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let group = try #require(chats.groups.first)

        let id = try await chats.forward(original, from: chats, in: .bot(scout), saying: "  For the review \n", to: .group(group))

        // Shown in the group at once, before the Hub has it.
        let shown = try #require(chats.messages(of: group).last)
        #expect(shown.id == id)
        #expect(shown.author == .you)
        #expect(shown.body == "For the review")
        #expect(shown.attachments.map(\.filename) == ["report.pdf"])
        #expect(shown.attachments.map(\.mediaType) == ["application/pdf"])
        let copy = try #require(shown.attachments.first)
        #expect(copy.id != original.id)
        #expect(await hub.downloads == 1)

        await chats.deliver(id)
        #expect(!chats.isUnsent(shown))
        let onHub = await hub.messages
        let sent = try #require(onHub.first { $0.id == id })
        #expect(sent.conversationID == crew.id)
        #expect(sent.body == "For the review")
        #expect(sent.attachments.map(\.id) == [copy.id])
        #expect(await hub.data(of: copy.id) == data)
        // Scout's conversation is as it was.
        #expect(onHub.filter { $0.conversationID == scout.conversationID }.count == 2)

        // Without a comment, it says what was sent, as a file sent alone does. The file is on the phone by now.
        let bare = try await chats.forward(original, from: chats, in: .bot(scout), saying: " ", to: .group(group))
        await chats.deliver(bare)
        let bareOnHub = await hub.messages.first { $0.id == bare }
        #expect(bareOnHub?.body == "Sent 1 attachment")
        #expect(await hub.downloads == 1)
    }

    /// Forward… offers the bots and groups the list shows, but the file's own conversation and those that take no
    /// messages, and search finds them by name. Recordings, comments and links are not offered for forwarding.
    @Test func forwardOffersOtherBotsAndGroupsThatTakeMessages() async throws {
        let hub = FakeHub()
        let crew = await hub.addGroup(named: "Crew", saying: "Morning")
        let house = await hub.addGroup(named: "House", saying: "Hi all")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        func names(leaving source: UUID, search: String = "") -> [String] {
            AttachmentForwarding.targets(in: [chats], leaving: source, search: search).map { $0.1.name }
        }

        #expect(Set(names(leaving: scout.conversationID)) == ["Crew", "House"])
        #expect(Set(names(leaving: crew.id)) == ["Scout", "House"])
        #expect(names(leaving: scout.conversationID, search: " cre ") == ["Crew"])
        #expect(names(leaving: scout.conversationID, search: "Nobody").isEmpty)
        try await chats.setArchived(true, .group(try #require(chats.groups.first { $0.id == house.id })))
        #expect(names(leaving: scout.conversationID) == ["Crew"])

        let file = LinkAttachment(id: UUID(), filename: "notes.txt", mediaType: "text/plain", byteCount: 5)
        #expect(AttachmentForwarding.canForward(file))
        var voice = file
        voice.voice = LinkVoice(transcript: "Hi", duration: 1, waveform: [0.5], localeIdentifier: "en-GB")
        #expect(!AttachmentForwarding.canForward(voice))
        var link = file
        link.url = URL(string: "https://example.com")
        #expect(!AttachmentForwarding.canForward(link))
    }

    /// The share sheet offers what the list shows, without asking the Hub: archived bots and groups stay out.
    @Test func theShareSheetOffersWhatTheListShows() async throws {
        let hub = FakeHub()
        let house = await hub.addGroup(named: "House", saying: "Hi all")
        let hubs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: hubs.appendingPathComponent(UUID().uuidString))
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        let offered = ShareTargets.all(in: hubs)
        #expect(Set(offered.map(\.name)) == ["Scout", "House"])
        #expect(offered.allSatisfy { $0.key.hub == chats.pairing.directory.lastPathComponent && $0.hubName == "Studio" })
        let group = try #require(offered.first { $0.isGroup })
        #expect(group.key.conversation == house.id)
        #expect(group.faces.map(\.name) == ["Scout"])
        #expect(offered.first { !$0.isGroup }?.key.conversation == scout.conversationID)

        try await chats.setArchived(true, .group(house))
        #expect(ShareTargets.all(in: hubs).map(\.name) == ["Scout"])
    }

    /// What the share sheet sends goes straight to the Hub, files first, and shows in the app like any message.
    @Test func whatTheShareSheetSendsReachesTheHub() async throws {
        let hub = FakeHub()
        let hubs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: hubs.appendingPathComponent(UUID().uuidString))
        defer { server.stop() }
        try await chats.reload()
        let target = try #require(ShareTargets.all(in: hubs).first)
        let data = Data((0..<(LinkProtocol.chunkSize + 1000)).map { UInt8($0 % 251) })
        let file = try PickedFiles.store(data, named: "Screenshot.png", type: .png)

        try await SharedSend.send("Look at this", files: [file], to: target, hubs: hubs)

        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let sent = try #require(chats.messages(of: scout).first { $0.body == "Look at this" })
        #expect(sent.attachments.map(\.filename) == ["Screenshot.png"])
        let attachment = try #require(sent.attachments.first)
        #expect(await hub.data(of: attachment.id) == data)
        // A picture alone says what was sent, as the app's own composer does.
        try await SharedSend.send("", files: [try PickedFiles.store(data, named: "Again.png", type: .png)], to: target, hubs: hubs)
        #expect(await hub.bodies(saying: "Sent 1 attachment") == 1)
    }

    /// Shortcuts offer the bots and groups the share sheet does. Open Chat opens either, and Send to Agent sends
    /// straight to the Hub, files alone saying what was sent.
    @Test func shortcutsOpenAndSendToBotsAndGroups() async throws {
        let hub = FakeHub()
        let house = await hub.addGroup(named: "House", saying: "Hi all")
        let hubs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: hubs.appendingPathComponent(UUID().uuidString))
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let key = CurrentHub.space(of: chats.pairing)

        let offered = ShortcutConversations.all(in: hubs)
        #expect(Set(offered.map(\.name)) == ["Scout", "House"])
        #expect(ShortcutConversations.all(in: hubs, matching: " hou ").map(\.name) == ["House"])
        // A bot keeps the ID its widgets and Call Agent know it by.
        let bot = try #require(offered.first { !$0.isGroup })
        #expect(bot.id == WidgetBot.id(hub: key, conversationID: scout.conversationID))
        let group = try #require(offered.first { $0.isGroup })
        let route = CurrentHub.route(to: try ShortcutConversations.link(to: group.id, in: hubs), in: [chats.pairing])
        #expect(route == NotificationRoute(topic: PushTopic.topic(for: chats.pairing), conversation: house.id))
        #expect(throws: ConversationGone.self) { try ShortcutConversations.link(to: "gone", in: hubs) }

        try await ShortcutConversations.send("", files: [IntentFile(data: Data("notes".utf8), filename: "notes.txt", type: .plainText)],
                                             to: group.id, in: hubs)
        #expect(await hub.bodies(saying: "Sent 1 attachment") == 1)
        try await ShortcutConversations.send("Look at this", files: [], to: bot.id, in: hubs)
        try await chats.reload()
        #expect(chats.messages(of: scout).contains { $0.body == "Look at this" && $0.attachments.isEmpty })
    }

    @Test func aBotsFileIsDownloadedOnceAndKept() async throws {
        let hub = FakeHub()
        let attachment = await hub.botSends(Data("report".utf8), named: "report.txt", mediaType: "text/plain")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        #expect(chats.messages(of: scout).last?.attachments == [attachment])

        let first = try await chats.file(for: attachment, in: scout)
        let second = try await chats.file(for: attachment, in: scout)

        #expect(try Data(contentsOf: first) == Data("report".utf8))
        #expect(first.lastPathComponent == "report.txt")
        #expect(first == second)
        #expect(await hub.downloads == 1)
    }

    /// A picture shown in two places at once, as in its bubble and the Shared list, comes down once.
    @Test func aFileAskedForTwiceAtOnceIsDownloadedOnce() async throws {
        let hub = FakeHub()
        let attachment = await hub.botSends(Data(repeating: 7, count: LinkProtocol.chunkSize * 3), named: "photo.png", mediaType: "image/png")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        async let first = chats.file(for: attachment, in: scout)
        async let second = chats.file(for: attachment, in: scout)
        #expect(try await first == second)
        #expect(await hub.downloads == 1)
    }

    /// Downloaded files are copies the Hub still has: left out of backups, and the least recently
    /// shown dropped past the limit. Files of messages not yet sent are never dropped.
    @Test func downloadedFilesStayOutOfBackupsAndTheOldestGoPastTheLimit() async throws {
        let hub = FakeHub()
        let older = await hub.botSends(Data(repeating: 1, count: 1000), named: "a.png", mediaType: "image/png")
        let old = await hub.botSends(Data(repeating: 2, count: 1000), named: "b.png", mediaType: "image/png")
        let recent = await hub.botSends(Data(repeating: 3, count: 1000), named: "c.png", mediaType: "image/png")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        for attachment in [older, old, recent] { _ = try await chats.file(for: attachment, in: scout) }
        // Shown again, so it is the most recently used.
        let kept = try await chats.file(for: older, in: scout)
        chats.retryPauses = [.zero]
        await hub.failSends(10)
        let draft = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try Data(repeating: 4, count: 1000).write(to: draft)
        try? await chats.send("Look", files: [OutgoingFile(url: draft, filename: "d.png", mediaType: "image/png")], to: scout)
        let unsent = try #require(chats.messages(of: scout).first { $0.body == "Look" }?.attachments.first)

        // The Hub has the downloads; a message not yet sent is the only copy of its files.
        #expect(Self.isBackedUp(kept) == false)
        #expect(Self.isBackedUp(try #require(chats.downloadedFile(for: unsent))) == true)

        chats.dropOldFiles(over: 2500)
        #expect(chats.downloadedFile(for: older) != nil)
        #expect(chats.downloadedFile(for: unsent) != nil)
        #expect(chats.downloadedFile(for: old) == nil)
        #expect(chats.downloadedFile(for: recent) == nil)
    }

    /// Files an earlier version kept without leaving them out of backups are left out at the next launch.
    @Test func filesKeptBeforeAreLeftOutOfBackupsAtLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = directory.appendingPathComponent("Files/\(UUID().uuidString)/photo.png")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: old)
        #expect(Self.isBackedUp(old) == true)

        HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).dropOldFiles()
        #expect(Self.isBackedUp(old) == false)
    }

    /// Whether the folder a file is kept in goes into the phone's backups.
    private static func isBackedUp(_ file: URL) -> Bool? {
        let folder = URL(fileURLWithPath: file.deletingLastPathComponent().path)
        return (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup).map { !$0 }
    }

    /// A picture's bubble drawn again, as when scrolled back into view, shows the picture before any
    /// task has run, rather than a placeholder.
    @Test func aPictureSeenBeforeShowsAtOnceWhenItsBubbleIsDrawnAgain() async throws {
        let red = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let hub = FakeHub()
        let attachment = await hub.botSends(red, named: "red.png", mediaType: "image/png")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        // As the first time its bubble showed: downloaded and decoded.
        _ = DecodedImages.downsampled(try await chats.file(for: attachment, in: scout), to: 720)

        let renderer = ImageRenderer(content: AttachmentView(chats: chats, thread: .bot(scout), attachment: attachment))
        renderer.scale = 1
        let pixel = try Self.centre(of: try #require(renderer.cgImage))
        #expect(pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60, "The bubble showed \(pixel), not the picture")
    }

    /// A picture a bot sends shows from the small copy the Hub makes, kept on the phone across launches;
    /// the file itself comes down only when opened.
    @Test func aPictureShowsFromTheHubsPreviewWithoutDownloadingIt() async throws {
        let hub = FakeHub()
        let attachment = await hub.botSends(Data(repeating: 1, count: 50_000), named: "photo.jpg", mediaType: "image/jpeg")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        let preview = try #require(try await chats.preview(of: attachment, in: scout))
        #expect(try Data(contentsOf: preview) == FakeHub.preview)
        #expect(try await chats.preview(of: attachment, in: scout) == preview)
        #expect(await hub.previewFetches == 1)
        #expect(await hub.downloads == 0)
        #expect(chats.downloadedFile(for: attachment) == nil)
        #expect(Self.isBackedUp(preview) == false)

        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.keptPreview(for: attachment) == preview)
    }

    /// A bubble drawn again shows the Hub's preview at once, as it does a downloaded picture.
    @Test func aPreviewSeenBeforeShowsAtOnceWhenItsBubbleIsDrawnAgain() async throws {
        let hub = FakeHub()
        let attachment = await hub.botSends(Data(repeating: 1, count: 50_000), named: "photo.jpg", mediaType: "image/jpeg")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        _ = DecodedImages.downsampled(try #require(try await chats.preview(of: attachment, in: scout)), to: 720)

        let renderer = ImageRenderer(content: AttachmentView(chats: chats, thread: .bot(scout), attachment: attachment))
        renderer.scale = 1
        let pixel = try Self.centre(of: try #require(renderer.cgImage))
        #expect(pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60, "The bubble showed \(pixel), not the preview")
        #expect(await hub.downloads == 0)
    }

    private static func centre(of image: CGImage) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return pixel
    }

    /// A shared noodlet's card shows at once after a relaunch, from what this phone kept of it.
    @Test func sharedCardsAreKeptAcrossLaunches() async throws {
        let hub = FakeHub()
        let racer = await hub.botSharesNoodlet("Racer")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let card = try #require(await chats.sharedAttachment(racer, in: scout).card)
        #expect(card.image == Data("racer picture".utf8))

        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.keptCard(for: racer) == card)
        #expect(await hub.cardFetches == 1)
    }

    @Test func onlyPublicWebLinksGetAPreview() {
        #expect(LinkPreview.firstURL(in: "See https://example.com/page and https://apple.com")?.absoluteString == "https://example.com/page")
        #expect(LinkPreview.firstURL(in: "[docs](https://swift.org/documentation)")?.host() == "swift.org")
        for text in ["http://localhost:8080", "http://192.168.1.4/admin", "mailto:a@b.com", "ftp://example.com", "no links"] {
            #expect(LinkPreview.firstURL(in: text) == nil, "\(text)")
        }
    }

    @Test func conversationsAlreadyThereAreNotUnread() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.reload()

        #expect(!chats.isUnread(try #require(chats.agents.first)))
    }

    /// A phone joining a Hub starts from what the person has read on their other devices: a conversation with a
    /// reply after the Hub's read mark is unread here too, from the first sync.
    @Test func aNewPhoneShowsWhatIsUnreadOnTheOtherDevices() async throws {
        let hub = FakeHub()
        await hub.botSays("Read on the Mac")
        let read = try #require(await hub.messages.last)
        let conversationID = await hub.bot.conversationID
        _ = await hub.reply(to: try LinkProtocol.encode(.markRead(LinkReadMark(conversationID: conversationID, messageID: read.id))))
        await hub.botSays("Not read yet")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.reload()

        #expect(chats.isUnread(try #require(chats.agents.first)))
    }

    /// The line under a name is what was last said; the Hub's own notices are left out, as on the Mac.
    @Test func theLatestMessageSkipsTheHubsOwnNotices() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        await hub.botSays("The report is ready")
        await hub.notice("Back on Claude Code")
        try await chats.reload()
        let scout = HubThread.bot(try #require(chats.agents.first))

        for detail in ConversationRowDetail.allCases {
            #expect(chats.line(for: scout, showing: detail) == "The report is ready", "\(detail)")
        }
    }

    /// A call needs the bot running now, unlike a message it can pick up later: not stopped, starting or failed,
    /// not paused, and its Hub in reach.
    @Test func onlyABotThatIsRunningCanBeCalled() async throws {
        let hub = FakeHub()
        await hub.takesCalls()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        for (phase, callable) in [(LinkBotPhase.ready, true), (.working, true), (.offline, false), (.starting, false), (.failed, false)] {
            try await chats.apply(.botPhase(botID: scout.id, phase: phase))
            #expect(chats.canCallNow(try #require(chats.agent(scout.id))) == callable, "\(phase)")
        }
    }

    /// A pinned circle's bubble shows the start of an unread reply, or else the bot's status.
    @Test func aPinnedBubbleShowsAnUnreadReplyBeforeTheStatus() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        func note() throws -> PinnedNote? { chats.note(for: .bot(try #require(chats.agents.first))) }
        try await chats.reload()
        #expect(try note() == nil)

        await hub.setStatus("Reviewing PR 42")
        try await chats.reload()
        #expect(try note() == .status("Reviewing PR 42"))

        await hub.botSays("Done,\n  all green")
        try await chats.reload()
        #expect(try note() == .unread("Done, all green"))

        chats.markRead(try #require(chats.agents.first))
        #expect(try note() == .status("Reviewing PR 42"))
    }

    @Test func aReplyIsUnreadUntilTheConversationIsOpened() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        await hub.botSays("Done")
        try await chats.reload()
        #expect(chats.isUnread(scout))
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).isUnread(scout))

        chats.markRead(scout)

        #expect(!chats.isUnread(scout))
        #expect(!HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).isUnread(scout))
    }

    @Test func aLaterReplyIsUnreadAgain() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        chats.markRead(scout)

        await hub.botSays("Hello again")
        try await chats.reload()

        #expect(chats.isUnread(scout))
    }

    /// Reading here tells the Hub, so the person's other devices show it read.
    @Test func readingHereIsKeptOnTheHub() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        await hub.botSays("Done")
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        chats.markRead(scout)

        let latest = try #require(await hub.messages.last?.createdAt)
        for _ in 0..<50 where await hub.bot.readUpTo != latest { try await Task.sleep(for: .milliseconds(100)) }
        #expect(await hub.bot.readUpTo == latest)
    }

    /// A conversation read on another device is read here too, whether heard at once or on the next sync.
    @Test func aConversationReadElsewhereIsReadHere() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        await hub.botSays("Done")
        try await chats.reload()
        #expect(chats.isUnread(scout))
        try await chats.apply(.readChanged(conversationID: scout.conversationID, upTo: try #require(chats.messages(of: scout).last?.createdAt)))
        #expect(!chats.isUnread(scout))

        await hub.botSays("Anything else?")
        try await chats.reload()
        #expect(chats.isUnread(scout))
        let latest = try #require(await hub.messages.last)
        _ = await hub.reply(to: try LinkProtocol.encode(.markRead(LinkReadMark(conversationID: scout.conversationID, messageID: latest.id))))
        try await chats.reload()
        #expect(!chats.isUnread(scout))
    }

    /// Each Hub gets its own topic, the same every time, once the phone listens on it; turned off, both stop.
    @Test func eachHubHearsWhereToLeaveWordOfUnreadReplies() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let subscriptions = RecordedSubscriptions()
        let notifications = HubNotifications(subscriptions: subscriptions, defaults: UserDefaults(suiteName: UUID().uuidString)!)

        await notifications.register([chats.pairing], allowed: true)
        let topic = PushTopic.topic(for: chats.pairing)
        #expect(await subscriptions.topics == [topic])
        #expect(await hub.pushTopics == [topic])
        #expect(PushTopic.topic(for: HubPairing(directory: chats.pairing.directory, deviceName: "iPhone")) == topic)
        #expect(PushTopic.topic(for: HubPairing(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), deviceName: "iPhone")) != topic)

        await notifications.register([chats.pairing], allowed: false)
        #expect(await subscriptions.topics.isEmpty)
        #expect(await hub.pushTopics.last == .some(nil))
    }

    /// A Hub the phone left stops notifying it, though its folder, and the topic in it, are gone.
    @Test func aHubLeftStopsNotifying() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let subscriptions = RecordedSubscriptions()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        await HubNotifications(subscriptions: subscriptions, defaults: defaults).register([chats.pairing], allowed: true)
        #expect(await subscriptions.topics.count == 1)

        try FileManager.default.removeItem(at: chats.pairing.directory)
        await HubNotifications(subscriptions: subscriptions, defaults: defaults).register([], allowed: true)
        #expect(await subscriptions.topics.isEmpty)
    }

    /// Without iCloud nothing could arrive, so the Hub is not asked to leave word.
    @Test func aHubIsGivenNoTopicNobodyListensOn() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        let subscriptions = RecordedSubscriptions()
        await subscriptions.fail()

        await HubNotifications(subscriptions: subscriptions, defaults: UserDefaults(suiteName: UUID().uuidString)!)
            .register([chats.pairing], allowed: true)
        #expect(await hub.pushTopics == [nil])
    }

    /// The phone hears of its own topic only, as a notification it can change before showing, one per conversation.
    @Test func theSubscriptionListensOnTheTopic() {
        let subscription = CloudKitSubscriptions.subscription(topic: "abc")
        #expect(subscription.recordType == LinkPush.recordType)
        #expect(subscription.predicate == NSPredicate(format: "%K == %@", LinkPush.topicField, "abc"))
        #expect(subscription.querySubscriptionOptions == [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = subscription.notificationInfo
        #expect(Set(info?.desiredKeys ?? []) == [LinkPush.topicField, LinkPush.conversationField, LinkPush.unreadField])
        #expect(info?.collapseIDKey == LinkPush.conversationField)
        #expect(info?.shouldSendMutableContent == true)
        #expect(info?.alertBody?.isEmpty == false)
        #expect(CloudKitSubscriptions.subscription(topic: "xyz").subscriptionID != subscription.subscriptionID)
    }

    /// The phone hears in silence when the Hub takes its word back, under a subscription that names the topic.
    @Test func theWithdrawalsSubscriptionListensInSilence() {
        let withdrawals = CloudKitSubscriptions.withdrawals(topic: "abc")
        #expect(withdrawals.recordType == LinkPush.recordType)
        #expect(withdrawals.predicate == NSPredicate(format: "%K == %@", LinkPush.topicField, "abc"))
        #expect(withdrawals.querySubscriptionOptions == [.firesOnRecordDeletion])
        #expect(withdrawals.notificationInfo?.shouldSendContentAvailable == true)
        #expect(withdrawals.notificationInfo?.alertBody == nil)
        #expect(withdrawals.notificationInfo?.soundName == nil)
        #expect(withdrawals.subscriptionID != CloudKitSubscriptions.subscription(topic: "abc").subscriptionID)
        #expect(PushTopic.withdrawal(subscriptionID: withdrawals.subscriptionID, recordName: "name")
            == PushWithdrawal(topic: "abc", recordName: "name"))
        #expect(PushTopic.withdrawal(subscriptionID: CloudKitSubscriptions.subscriptionID("abc"), recordName: "name") == nil)
        #expect(PushTopic.withdrawal(subscriptionID: nil, recordName: "name") == nil)
    }

    /// The icon counts the listed conversations with a reply not read yet, once the live stream is
    /// open; read here, a conversation leaves the count at once.
    @Test func theIconCountsUnreadConversations() async throws {
        let hub = FakeHub()
        let hubs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: hubs.appendingPathComponent(UUID().uuidString))
        defer { server.stop() }
        try await chats.reload()
        let house = await hub.addGroup(named: "House", saying: "Dinner at eight.")
        await hub.botSays("Done")
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        // What this phone kept may miss replies until the Hub is heard.
        #expect(chats.badgedConversations == nil)

        let following = Task { await chats.follow() }
        defer { following.cancel() }
        for _ in 0..<100 where !chats.isConnected { try await Task.sleep(for: .milliseconds(100)) }
        #expect(chats.badgedConversations == [scout.conversationID, house.id])
        AppBadge.publish([chats])
        #expect(AppBadge.unread(in: chats.pairing.directory) == [scout.conversationID, house.id])
        #expect(AppBadge.count(hubs: hubs) == 2)

        chats.markRead(scout)
        #expect(AppBadge.unread(in: chats.pairing.directory) == [house.id])
        #expect(chats.badgedConversations == [house.id])

        try await chats.setArchived(true, .group(house))
        #expect(chats.badgedConversations == [])
    }

    /// A group muted on any device leaves the icon's count, though its row still shows the reply unread.
    @Test func aMutedGroupIsNotCountedOnTheIcon() async throws {
        let hub = FakeHub()
        let hubs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: hubs.appendingPathComponent(UUID().uuidString))
        defer { server.stop() }
        try await chats.reload()
        let house = await hub.addGroup(named: "House", saying: "Dinner at eight.")
        await hub.botSays("Done")
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let following = Task { await chats.follow() }
        defer { following.cancel() }
        for _ in 0..<100 where !chats.isConnected { try await Task.sleep(for: .milliseconds(100)) }
        #expect(chats.badgedConversations == [scout.conversationID, house.id])

        try await chats.apply(.notificationsChanged(conversationID: house.id, notifications: .muted))
        #expect(chats.isMuted(HubThread.group(house)))
        #expect(chats.isUnread(HubThread.group(house)))
        #expect(!chats.countsAsUnread(HubThread.group(house)))
        #expect(chats.badgedConversations == [scout.conversationID])
        // Bots' own conversations always notify.
        try await chats.apply(.notificationsChanged(conversationID: scout.conversationID, notifications: .muted))
        #expect(!chats.isMuted(scout))

        try await chats.apply(.notificationsChanged(conversationID: house.id, notifications: .all))
        #expect(chats.badgedConversations == [scout.conversationID, house.id])
    }

    /// A group in Mentions only, set on its own or for all groups, counts on the icon only once a reply names the user,
    /// though its other replies still show unread. Muted is silent even for a mention.
    @Test func aGroupInMentionsOnlyCountsOnlyItsMentions() async throws {
        let hub = FakeHub()
        let hubs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: hubs.appendingPathComponent(UUID().uuidString))
        defer { server.stop() }
        try await chats.reload()
        let house = await hub.addGroup(named: "House", saying: "Dinner at eight. Petkov cooks.")
        let thread = HubThread.group(house)
        await hub.botSays("Done")
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let following = Task { await chats.follow() }
        defer { following.cancel() }
        for _ in 0..<100 where !chats.isConnected { try await Task.sleep(for: .milliseconds(100)) }
        #expect(chats.badgedConversations == [scout.conversationID, house.id])

        try await chats.apply(.groupNotificationsChanged(notifications: .mentions))
        #expect(chats.groupNotifications == .mentions)
        #expect(chats.notifications(of: thread) == .mentions)
        #expect(chats.notifications(of: scout) == .all)
        #expect(chats.countsAsUnread(thread), "Its replies still show unread")
        #expect(chats.badgedConversations == [scout.conversationID])

        await hub.botSays("petko, the table is set.", in: house.id)
        try await chats.reload()
        #expect(chats.hasUnreadMention(thread))
        #expect(chats.badgedConversations == [scout.conversationID, house.id])

        try await chats.apply(.notificationsChanged(conversationID: house.id, notifications: .muted))
        #expect(chats.badgedConversations == [scout.conversationID], "Muted is silent even for a mention")
        try await chats.apply(.notificationsChanged(conversationID: house.id, notifications: .default))
        #expect(chats.chosenNotifications(of: thread) == nil)
        #expect(chats.badgedConversations == [scout.conversationID, house.id])
        chats.markRead(thread)
        #expect(chats.badgedConversations == [scout.conversationID])
    }

    @Test func aNotificationLeadsToItsConversation() {
        let conversation = UUID()
        let route = PushTopic.route(fields: [LinkPush.topicField: "abc", LinkPush.conversationField: conversation.uuidString])
        #expect(route == NotificationRoute(topic: "abc", conversation: conversation))
        #expect(PushTopic.route(fields: [LinkPush.topicField: "abc"]) == nil)
    }

    /// A notification names the bot and shows its latest reply, fetched from the Hub whose topic it came under.
    @Test func aNotificationShowsTheBotAndItsReply() async throws {
        let hub = FakeHub()
        await hub.botSays("All done.")
        let hubs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: hubs.appendingPathComponent(UUID().uuidString))
        defer { server.stop() }
        let conversation = await hub.bot.conversationID

        let route = NotificationRoute(topic: PushTopic.topic(for: chats.pairing), conversation: conversation)
        let reply = try #require(await ReplyNotification.content(for: route, hubs: hubs))
        #expect((reply.title, reply.body) == ("Scout", "All done."))
        // The bot who said it, so iOS shows its picture and suggests the conversation when sharing.
        #expect(reply.sender?.name == "Scout")
        #expect(reply.target.key == ShareTarget.Key(hub: chats.pairing.directory.lastPathComponent, conversation: conversation))
        #expect(await ReplyNotification.content(for: NotificationRoute(topic: "unknown", conversation: conversation), hubs: hubs) == nil)
    }

    /// A group's notification is the group's, with the bot that wrote last.
    @Test func aGroupsNotificationShowsTheGroupAndWhoReplied() async throws {
        let hub = FakeHub()
        let house = await hub.addGroup(named: "House", saying: "Lunch is ready")
        let hubs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: hubs.appendingPathComponent(UUID().uuidString))
        defer { server.stop() }

        let route = NotificationRoute(topic: PushTopic.topic(for: chats.pairing), conversation: house.id)
        let reply = try #require(await ReplyNotification.content(for: route, hubs: hubs))
        #expect((reply.title, reply.body) == ("House", "Scout: Lunch is ready"))
        #expect(reply.sender?.name == "Scout")
        #expect(reply.target.isGroup)
    }

    /// Tables stay in the conversation; the notification and the pinned bubble show the text around them.
    @Test func notificationsAndPinnedBubblesLeaveTablesOut() async throws {
        let hub = FakeHub()
        let hubs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: hubs.appendingPathComponent(UUID().uuidString))
        defer { server.stop() }
        try await chats.reload()
        await hub.botSays("Numbers:\n\n| Day | Messages |\n|---|---|\n| Sep 1 | 4 |\n\nAll quiet.")
        let conversation = await hub.bot.conversationID
        let route = NotificationRoute(topic: PushTopic.topic(for: chats.pairing), conversation: conversation)
        #expect(await ReplyNotification.content(for: route, hubs: hubs)?.body == "Numbers:\n\nAll quiet.")
        try await chats.reload()
        #expect(chats.note(for: .bot(try #require(chats.agents.first))) == .unread("Numbers: All quiet."))

        await hub.botSays("| A |\n|---|\n| 1 |")
        #expect(await ReplyNotification.content(for: route, hubs: hubs)?.body == "Sent a table")
    }

    @Test func unsentTextIsKeptPerConversation() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        chats.setDraft("Half a thought", for: scout)

        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).draft(for: scout) == "Half a thought")
        chats.setDraft("", for: scout)
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).draft(for: scout) == "")
    }

    @Test func longMessagesFoldAtTheMacsLimits() {
        #expect(!MessageFolding.isLong("A short reply."))
        #expect(!MessageFolding.isLong(Array(repeating: "line", count: 12).joined(separator: "\n")))
        #expect(MessageFolding.isLong(Array(repeating: "line", count: 13).joined(separator: "\n")))
        #expect(MessageFolding.isLong(String(repeating: "a", count: 1201)))
    }

    @Test func myReactionReachesTheHubAndComesBack() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let hello = try #require(chats.messages(of: scout).first)

        try await chats.toggleReaction("👍", on: hello, in: scout)
        #expect(chats.messages(of: scout).first?.reactions == [LinkReaction(author: .you, emoji: "👍")])

        try await chats.toggleReaction("👍", on: try #require(chats.messages(of: scout).first), in: scout)
        #expect(chats.messages(of: scout).first?.reactions == [])
    }

    @Test func pushedChangesUpdateMessagesAndStatus() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        var hello = try #require(chats.messages(of: scout).first)
        hello.reactions = [LinkReaction(author: .bot(scout.id), emoji: "🎉")]

        try await chats.apply(.messageChanged(hello))
        try await chats.apply(.botPhase(botID: scout.id, phase: .working))

        #expect(chats.messages(of: scout).first?.reactions == hello.reactions)
        #expect(chats.agent(scout.id)?.phase == .working)
    }

    /// Coming back to the app syncs everything again; when nothing changed on the Hub, nothing on screen is drawn again.
    @Test func aSyncThatBringsNothingNewRedrawsNothing() async throws {
        let hub = FakeHub()
        let crew = await hub.addGroup(named: "Crew", saying: "Morning")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        let redrawn = try await redraws {
            _ = chats.messages(of: scout)
            _ = chats.messages(of: crew)
            _ = chats.listedThreads
            _ = chats.hasEarlier(scout)
            _ = chats.phase(of: scout)
        } after: {
            try await chats.reload()
        }
        #expect(!redrawn)
    }

    /// As on the Mac, an open conversation is drawn again for its own messages and its own bot or group alone.
    @Test func aChangeInOneConversationDoesNotRedrawAnother() async throws {
        let hub = FakeHub()
        let crew = await hub.addGroup(named: "Crew", saying: "Morning")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        await hub.botSays("Anything else?")
        let redrawn = try await redraws {
            _ = chats.messages(of: crew)
            _ = chats.thread(crew.id)
        } after: {
            try await chats.apply(.conversationChanged(conversationID: scout.conversationID, count: 3))
            try await chats.apply(.botPhase(botID: scout.id, phase: .working))
        }
        #expect(!redrawn)
        #expect(chats.messages(of: scout).last?.body == "Anything else?")
        #expect(chats.agent(scout.id)?.phase == .working)

        // Its own still are.
        await hub.botSays("Crew, report", in: crew.id)
        #expect(try await redraws { _ = chats.messages(of: crew) } after: {
            try await chats.apply(.conversationChanged(conversationID: crew.id, count: 2))
        })
    }

    /// Everything syncs again as the app comes back: the conversation on screen first, then the rest a few at a time
    /// rather than one after another.
    @Test func aSyncLoadsTheConversationOnScreenFirstAndTheRestTogether() async throws {
        let hub = FakeHub()
        var crews: [LinkGroup] = []
        for index in 0..<8 { crews.append(await hub.addGroup(named: "Crew \(index)", saying: "Morning")) }
        let scout = await hub.bot
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        for crew in crews { await hub.botSays("Report", in: crew.id) }

        chats.shownConversation = crews[5].id
        await hub.slowPages(.milliseconds(100))
        try await chats.reload()

        let order = await hub.pageOrder
        #expect(order.first == crews[5].id)
        #expect(Set(order) == Set(crews.map(\.id) + [scout.conversationID]))
        #expect(await hub.mostPagesInFlight > 1)
        #expect(await hub.mostPagesInFlight <= HubChats.loadingWidth)
        for crew in crews { #expect(chats.messages(of: crew).map(\.body) == ["Morning", "Report"]) }
        #expect(chats.error == nil)
    }

    /// An admin's Users screen follows the Hub's users, as the Hub pushes that they changed.
    @Test func theHubSayingUsersChangedIsCounted() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        #expect(chats.usersChanges == 0)
        try await chats.apply(.usersChanged)
        try await chats.apply(.usersChanged)
        #expect(chats.usersChanges == 2)
    }

    @Test func aVoiceMessageTravelsWithItsTranscript() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        try Data([1, 2, 3]).write(to: audio)
        let voice = LinkVoice(transcript: "Book a table", duration: 2, waveform: [0.2, 0.8], localeIdentifier: "en_GB")

        try await chats.sendVoice(audio, voice: voice, to: scout)

        let sent = try #require(chats.messages(of: scout).first { $0.attachments.first?.voice != nil })
        #expect(sent.body == "Voice message")
        #expect(sent.attachments.first?.voice == voice)
        #expect(sent.attachments.first?.mediaType == "audio/x-caf")
    }

    @Test func typingAtOffersBotsByNameAsOnTheMac() {
        let scout = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Scout", provider: "codex"), createdAt: Date())
        let atlas = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Atlas", provider: "codex"), createdAt: Date())
        let sam = LinkBot(id: UUID(), conversationID: UUID(), draft: LinkBotDraft(name: "Sam", provider: "codex"), createdAt: Date())

        let text = "Ask @s"
        let request = try? #require(MentionCompletion.request(in: text, caret: text.utf16.count))
        #expect(request?.query == "s")
        // This conversation's bot first, then by name.
        #expect(request?.matches([atlas, sam, scout], preferred: scout.id).map(\.draft.name) == ["Scout", "Atlas", "Sam"])
        #expect(request?.replacing(with: "Scout", in: text) == "Ask Scout ")

        #expect(MentionCompletion.request(in: "mail@home", caret: 9) == nil)
        #expect(MentionCompletion.request(in: "Hi", caret: 2) == nil)
    }

    /// Backgrounds are the Hub's: the phone shows what is there, fetching a small copy once, and
    /// what it sets goes to the Hub for every device.
    @Test func backgroundsAreKeptOnTheHub() async throws {
        let hub = FakeHub()
        let movie = Data("a small movie".utf8)
        await hub.setBackground(LinkBackground(media: "\(UUID()).mov", mediaKind: "video"), compact: movie)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        #expect(chats.background(for: scout).mediaKind == .video)
        let video = try #require(chats.backgroundImageURL(for: scout))
        #expect(video.pathExtension == "mp4")
        #expect(try Data(contentsOf: video) == movie)
        try await chats.reload()
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.backgroundImageURL(for: scout) == video)
        #expect(await hub.backgroundFetches == 1)

        try await chats.setBackground(ConversationBackground(preset: .ocean), for: scout)
        #expect(await hub.bot.background == LinkBackground(preset: "ocean"))
        #expect(chats.background(for: scout).preset == .ocean)
        #expect(chats.backgroundImageURL(for: scout) == nil)
        #expect(!FileManager.default.fileExists(atPath: video.path))

        let photo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.pngData()!
        try await chats.setBackground(photo: photo, for: scout)
        let image = try #require(chats.backgroundImageURL(for: scout))
        #expect(chats.background(for: scout).mediaKind == .image)
        #expect(UIImage(contentsOfFile: image.path) != nil)
        #expect(await hub.backgroundUpload == (try Data(contentsOf: image)))
        #expect(await hub.backgroundFetches == 1)

        // Another device takes it away.
        await hub.setBackground(LinkBackground())
        try await chats.apply(.backgroundChanged(conversationID: scout.conversationID, background: LinkBackground()))
        #expect(chats.background(for: scout).isDefault)
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }

    /// Groups made on another device are listed with the bots, with what was said in them.
    @Test func groupsListWithTheirConversations() async throws {
        let hub = FakeHub()
        let group = await hub.addGroup(named: "Crew", saying: "Morning")
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }

        try await chats.reload()

        #expect(chats.groups.map(\.draft.name) == ["Crew"])
        #expect(chats.sortedThreads.map(\.id) == [group.id, await hub.bot.id])
        #expect(chats.latestMessage(of: group)?.body == "Morning")
        #expect(chats.members(of: group).map(\.draft.name) == ["Scout"])
    }

    /// A group made, renamed and deleted from the phone reaches the Hub, and leaves no pin or saved copy behind.
    @Test func aGroupIsMadeEditedAndDeletedOnTheHub() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot

        var group = try await chats.createGroup(LinkGroupDraft(name: "Crew", botIDs: [scout.id]))
        #expect(await hub.groups.map(\.draft.name) == ["Crew"])
        group.draft.name = "Night Crew"
        try await chats.updateGroup(group)
        #expect(chats.groups.map(\.draft.name) == ["Night Crew"])
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).groups.map(\.draft.name) == ["Night Crew"])
        chats.togglePin(group)

        try await chats.deleteGroup(group)

        #expect(chats.groups.isEmpty)
        #expect(await hub.groups.isEmpty)
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.groups.isEmpty)
        #expect(!relaunched.isPinned(group))
    }

    /// A group made on another device shows once the Hub says groups changed.
    @Test func aGroupMadeElsewhereShowsWhenTheHubSaysSo() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let group = await hub.addGroup(named: "Crew", saying: "Morning")

        try await chats.apply(.groupsChanged)

        #expect(chats.groups.map(\.id) == [group.id])
        #expect(chats.latestMessage(of: group)?.body == "Morning")
    }

    /// In a group, a bot's name heads each run of its messages, as in Messages.
    @Test func groupMessagesNameTheirBotAtTheStartOfEachRun() {
        let (scout, atlas, conversation) = (UUID(), UUID(), UUID())
        let messages = [(LinkMessage.Author.bot(scout), 1), (.bot(scout), 2), (.you, 3), (.bot(scout), 4), (.bot(atlas), 5), (.system, 6)]
            .map { LinkMessage(id: UUID(), conversationID: conversation, author: $0.0, body: "\($0.1)",
                               createdAt: Date(timeIntervalSince1970: TimeInterval($0.1)), delivered: true) }
        let names = [scout: "Scout", atlas: "Atlas"]

        let labels = HubChats.authorLabels(in: messages) { names[$0] }

        #expect(messages.compactMap { labels[$0.id] } == ["Scout", "Scout", "Atlas"])
        #expect(labels[messages[1].id] == nil)
    }

    /// In a group, a bot's picture sits beside the last of each run of its messages, as in Messages.
    @Test func groupMessagesShowTheirBotAtTheEndOfEachRun() {
        let (scout, atlas, conversation) = (UUID(), UUID(), UUID())
        let messages = [(LinkMessage.Author.bot(scout), 1), (.bot(scout), 2), (.you, 3), (.bot(scout), 4), (.bot(atlas), 5), (.system, 6)]
            .map { LinkMessage(id: UUID(), conversationID: conversation, author: $0.0, body: "\($0.1)",
                               createdAt: Date(timeIntervalSince1970: TimeInterval($0.1)), delivered: true) }

        let avatars = HubChats.authorAvatars(in: messages)

        #expect(messages.compactMap { avatars[$0.id] } == [scout, scout, atlas])
        #expect(avatars[messages[0].id] == nil)
        #expect(avatars[messages[1].id] == scout)
    }

    /// A bot's picture in a group offers what the Mac's profile does: reply, its own conversation, a call, editing.
    @Test func groupBotProfileOffersTheMacsActions() {
        let draft = LinkBotDraft(name: "Scout", provider: "claude")
        let own = LinkBot(id: UUID(), conversationID: UUID(), draft: draft, createdAt: Date(), canCall: true)
        let shared = LinkBot(id: UUID(), conversationID: UUID(), draft: draft, createdAt: Date(), owner: "Ada")

        #expect(AgentProfile.actions(for: own, canOpen: true, inCall: false, canCallNow: true) == [.reply, .message, .call, .edit])
        // A bot someone shared is only talked with; one already on a call is not called again.
        #expect(AgentProfile.actions(for: shared, canOpen: true, inCall: false, canCallNow: true) == [.reply, .message])
        #expect(AgentProfile.actions(for: own, canOpen: false, inCall: true, canCallNow: true) == [.reply, .edit])
        // Nor is one that is not running now.
        #expect(AgentProfile.actions(for: own, canOpen: true, inCall: false, canCallNow: false) == [.reply, .message, .edit])
        #expect(AgentProfile.replying(to: "Scout", draft: "what do you think?") == "Scout, what do you think?")
    }

    /// Opening a bot's conversation from a group goes on top of it, or back to it when it is already open beneath.
    @Test func openingAConversationFromAGroupStacksOrGoesBack() {
        let (direct, group) = (ChatLink(hub: "Home", thread: UUID()), ChatLink(hub: "Home", thread: UUID()))

        #expect(ChatLink.path([group], opening: direct) == [group, direct])
        #expect(ChatLink.path([direct, group], opening: direct) == [direct])
    }

    @Test func botPicturesAreShrunkAndStoredAsTheMacStoresThem() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        }.pngData()!

        let stored = try BotPicture.prepare(big)

        let image = try #require(UIImage(data: stored)?.cgImage)
        #expect(max(image.width, image.height) == 512)
        #expect(stored.starts(with: [0xFF, 0xD8]))
    }

    /// A send that fails is tried again by itself while nothing newer has come, and arrives once.
    @Test func aFailedSendIsTriedAgainWhileItIsTheNewest() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot
        chats.retryPauses = [.zero, .zero, .zero]
        await hub.failSends(2)

        try await chats.send("Hi", to: scout)

        let sent = try #require(chats.messages(of: scout).first { $0.body == "Hi" })
        #expect(chats.delivery(of: sent) == "Delivered")
        #expect(await hub.bodies(saying: "Hi") == 1)
    }

    /// When it keeps failing, the message itself says so, rather than an error under the conversation,
    /// and still does after the app is opened again.
    @Test func aSendThatKeepsFailingIsMarkedOnTheMessage() async throws {
        let hub = FakeHub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (chats, server) = try await paired(to: hub, directory: directory)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot
        chats.retryPauses = [.zero, .zero]
        await hub.failSends(10)

        try await chats.send("Hi", to: scout)

        let sent = try #require(chats.messages(of: scout).last)
        #expect(sent.body == "Hi")
        #expect(chats.delivery(of: sent) == "Not delivered")
        #expect(chats.unsentReason(of: sent) == "The Hub did not answer in time.")
        let relaunched = HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone"))
        #expect(relaunched.messages(of: scout).last?.id == sent.id)
        #expect(relaunched.delivery(of: sent) == "Not delivered")
    }

    /// Once the conversation has moved on, a failed message is never sent by itself: out of its place it
    /// may no longer make sense. Still the newest, it goes when the Hub answers again.
    @Test func aFailedMessageIsSentAgainOnlyWhileItIsTheNewest() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot
        chats.retryPauses = [.zero]
        await hub.failSends(10)
        try await chats.send("First", to: scout)
        try await chats.send("Second", to: scout)
        await hub.failSends(0)

        try await chats.reload()

        let messages = chats.messages(of: scout)
        let first = try #require(messages.first { $0.body == "First" })
        let second = try #require(messages.first { $0.body == "Second" })
        #expect(await hub.bodies(saying: "First") == 0)
        #expect(chats.delivery(of: first) == "Not delivered")
        #expect(!chats.canTryAgain(first))
        #expect(await hub.bodies(saying: "Second") == 1)
        #expect(chats.delivery(of: second) == "Delivered")
    }

    /// The Hub may have taken a message whose answer was lost; its copy settles it, with no second one.
    @Test func aMessageTheHubGotDespiteTheFailureIsNotSentTwice() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot
        chats.retryPauses = [.zero]
        await hub.failSends(1, keeping: true)
        try await chats.send("Hi", to: scout)

        try await chats.reload()

        let sent = try #require(chats.messages(of: scout).first { $0.body == "Hi" })
        #expect(chats.delivery(of: sent) == "Delivered")
        #expect(chats.unsentReason(of: sent) == nil)
        #expect(await hub.bodies(saying: "Hi") == 1)
    }

    /// Edit and Send puts a failed message's text and files back to send anew; Delete drops it.
    @Test func aFailedMessageCanBeTakenBackOrDeleted() async throws {
        let hub = FakeHub()
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = await hub.bot
        chats.retryPauses = [.zero]
        await hub.failSends(10)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("notes".utf8).write(to: file)
        try await chats.send("Look", files: [OutgoingFile(url: file, filename: "notes.txt", mediaType: "text/plain")], to: scout)
        try await chats.send("Hi", to: scout)
        let look = try #require(chats.messages(of: scout).first { $0.body == "Look" })
        let hi = try #require(chats.messages(of: scout).first { $0.body == "Hi" })

        let (text, files) = try chats.takeBack(look, in: scout)
        chats.delete(hi, in: scout)

        #expect(text == "Look")
        #expect(files.map(\.filename) == ["notes.txt"])
        #expect(try Data(contentsOf: try #require(files.first).url) == Data("notes".utf8))
        #expect(!chats.messages(of: scout).contains { $0.id == look.id || $0.id == hi.id })
    }

    /// A longer message grows the field over the conversation, as in Messages; the conversation keeps
    /// its place and its gap at the end.
    @Test func typingMoreLinesLeavesTheConversationWhereItIs() async throws {
        let hub = FakeHub()
        for index in 1..<40 { await hub.botSays(String(repeating: "Message \(index) says something. ", count: 1 + index % 4)) }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatView(chats: chats, threadID: scout.id) })
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))

        let conversation = try #require(Self.view(UIScrollView.self, in: window) { !($0 is UITextView) && $0.contentSize.height > window.bounds.height })
        let field = try #require(Self.view(PastingTextView.self, in: window) { _ in true })
        field.becomeFirstResponder()
        field.insertText("Hello")
        try await Task.sleep(for: .milliseconds(300))
        let (offset, gap, height) = (conversation.contentOffset.y, conversation.adjustedContentInset.bottom, field.bounds.height)

        field.insertText("\n\n\n")
        try await Task.sleep(for: .milliseconds(300))

        #expect(field.bounds.height > height)
        #expect(conversation.adjustedContentInset.bottom == gap)
        #expect(conversation.contentOffset.y == offset)
    }

    /// Sending and dictating bring the keyboard up and down; the conversation stays at its end, with no gap after it.
    @Test func theKeyboardComingAndGoingKeepsTheConversationAtItsEnd() async throws {
        let hub = FakeHub()
        for index in 1..<40 { await hub.botSays(String(repeating: "Message \(index) says something. ", count: 1 + index % 4)) }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatView(chats: chats, threadID: scout.id) })
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))
        let conversation = try #require(Self.view(UIScrollView.self, in: window) { !($0 is UITextView) && $0.contentSize.height > window.bounds.height })
        let field = try #require(Self.view(PastingTextView.self, in: window) { _ in true })
        func pastEnd() -> CGFloat {
            conversation.contentOffset.y - (conversation.contentSize.height + conversation.adjustedContentInset.bottom - conversation.bounds.height)
        }
        var steps: [(String, CGFloat)] = [("opened", pastEnd())]

        field.becomeFirstResponder()
        try await Task.sleep(for: .seconds(1))
        steps.append(("keyboard up", pastEnd()))
        try await chats.send("Hi there", to: scout)
        try await Task.sleep(for: .seconds(1))
        steps.append(("sent", pastEnd()))
        field.resignFirstResponder()
        try await Task.sleep(for: .seconds(1))
        steps.append(("keyboard down", pastEnd()))

        for (step, past) in steps { #expect(abs(past) < 1, "\(step): \(past) points past the end") }
    }

    /// The first message sent after opening a long conversation from the list, with the keyboard up, ends
    /// just above the composer, as later ones do, rather than leaving the screen blank until it is scrolled.
    /// Long replies make the rows the conversation has not laid out yet a poor guess of their height.
    @Test(arguments: [false, true]) func theFirstMessageSentWithTheKeyboardUpEndsAboveTheComposer(longReplies: Bool) async throws {
        let hub = FakeHub()
        // More than a page, so earlier messages wait on the Hub as in a conversation used for a while.
        for index in 1..<120 {
            if longReplies, index.isMultiple(of: 3) {
                let points = (1...(2 + index % 14)).map { "• Point \($0) of reply \(index), which runs long enough to wrap over more than one line." }
                await hub.botSays("Reply \(index):\n\n" + points.joined(separator: "\n"))
            } else {
                await hub.botSays(String(repeating: "Message \(index) says something. ", count: 1 + index % 4))
            }
        }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let path = OpenChats()
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ReopenedChat(chats: chats, path: path))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        path.threads = [scout.id]
        try await Task.sleep(for: .seconds(1))
        let conversation = try #require(Self.view(UIScrollView.self, in: window) { !($0 is UITextView) && $0.contentSize.height > window.bounds.height })
        let field = try #require(Self.view(PastingTextView.self, in: window) { _ in true })
        func pastEnd() -> CGFloat {
            conversation.contentOffset.y - (conversation.contentSize.height + conversation.adjustedContentInset.bottom - conversation.bounds.height)
        }
        func state() -> String {
            "offset \(conversation.contentOffset.y), content \(conversation.contentSize.height), " +
                "inset \(conversation.adjustedContentInset.bottom), height \(conversation.bounds.height), messages \(chats.messages(of: scout).count)"
        }
        var steps: [(String, CGFloat, String)] = [("opened", pastEnd(), state())]

        // The simulator shows no keyboard, so its room is made as a phone's keyboard makes it: the safe
        // area's bottom rises, animated, with the notice the composer moves on.
        field.becomeFirstResponder()
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        UIView.animate(withDuration: 0.35) {
            host.additionalSafeAreaInsets.bottom = 300
            host.view.layoutIfNeeded()
        }
        try await Task.sleep(for: .seconds(1))
        steps.append(("keyboard up", pastEnd(), state()))
        for send in ["first", "second"] {
            try await chats.send("Hi there, the \(send) time", to: scout)
            try await Task.sleep(for: .seconds(1))
            steps.append(("\(send) sent", pastEnd(), state()))
        }

        for (step, past, state) in steps { #expect(abs(past) < 1, "\(step): \(past) points past the end (\(state))") }
    }

    /// A scroll that stops beyond the end leaves nothing above the composer, as a phone showed after the
    /// first message sent with the keyboard up. The conversation goes back to its end by itself rather
    /// than staying blank until it is scrolled by hand.
    @Test func aConversationLeftPastItsEndGoesBackToIt() async throws {
        let hub = FakeHub()
        for index in 1..<40 { await hub.botSays(String(repeating: "Message \(index) says something. ", count: 1 + index % 4)) }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)

        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatView(chats: chats, threadID: scout.id) })
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))
        let conversation = try #require(Self.view(UIScrollView.self, in: window) { !($0 is UITextView) && $0.contentSize.height > window.bounds.height })
        func end() -> CGFloat { conversation.contentSize.height + conversation.adjustedContentInset.bottom - conversation.bounds.height }
        try await chats.send("Hi there", to: scout)
        try await Task.sleep(for: .seconds(1))

        // Set from code, as SwiftUI sets it, a scroll view's offset is not held to its content.
        conversation.setContentOffset(CGPoint(x: conversation.contentOffset.x, y: end() + conversation.bounds.height), animated: false)
        try await Task.sleep(for: .seconds(1))

        #expect(abs(conversation.contentOffset.y - end()) < 1, "\(conversation.contentOffset.y - end()) points past the end")
    }

    /// The message field sits as low as the bots list's search field, and the conversation still ends
    /// 16 points above it.
    @Test func theComposerSitsAsLowAsSearch() async throws {
        let hub = FakeHub()
        for index in 1..<40 { await hub.botSays(String(repeating: "Message \(index) says something. ", count: 1 + index % 4)) }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)

        let list = UIWindow(windowScene: scene)
        list.rootViewController = UIHostingController(rootView: NavigationStack {
            List { Text("Bot") }.listStyle(.plain).searchable(text: .constant(""), prompt: "Search")
        })
        list.isHidden = false
        try await Task.sleep(for: .seconds(1))
        let search = try #require(Self.view(UISearchTextField.self, in: list) { _ in true })
        let capsule = try #require(sequence(first: search as UIView, next: \.superview).first { $0.bounds.height > search.bounds.height })
        let searchBottom = capsule.convert(capsule.bounds, to: list).maxY
        list.isHidden = true

        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatView(chats: chats, threadID: scout.id) })
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))
        let conversation = try #require(Self.view(UIScrollView.self, in: window) { !($0 is UITextView) && $0.contentSize.height > window.bounds.height })
        let field = try #require(Self.view(PastingTextView.self, in: window) { _ in true })
        // The editor includes the padding inside the glass around its text.
        let fieldBottom = field.convert(field.bounds, to: window).maxY
        let end = conversation.convert(conversation.bounds, to: window).maxY - conversation.adjustedContentInset.bottom

        #expect(abs(fieldBottom - searchBottom) < 1, "The field ends at \(fieldBottom), search at \(searchBottom)")
        #expect(abs(fieldBottom - ChatView.controlHeight - end - 16) < 1, "The field ends at \(fieldBottom), the conversation at \(end)")
    }

    /// Left at its end and opened again, a conversation shows its end again.
    @Test func aConversationLeftAtItsEndReopensThere() async throws {
        let hub = FakeHub()
        for index in 1..<30 {
            let points = (1...(2 + index % 14)).map { "• Point \($0) of reply \(index), which runs long enough to wrap over more than one line." }
            await hub.botSays("Reply \(index):\n\n" + points.joined(separator: "\n"))
            await hub.botSays(String(repeating: "Message \(index) says something. ", count: 1 + index % 4))
        }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)

        let path = OpenChats()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ReopenedChat(chats: chats, path: path))
        window.isHidden = false
        defer { window.isHidden = true }
        func conversation() throws -> UIScrollView {
            try #require(Self.view(UIScrollView.self, in: window) { !($0 is UITextView) && $0.contentSize.height > window.bounds.height })
        }
        func end(of view: UIScrollView) -> CGFloat { view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height }

        path.threads = [scout.id]
        try await Task.sleep(for: .seconds(1))
        // Scrolled up and back down to the end, as a person reading does.
        let opened = try conversation()
        opened.setContentOffset(CGPoint(x: opened.contentOffset.x, y: opened.contentOffset.y - 2000), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<5 {
            opened.setContentOffset(CGPoint(x: opened.contentOffset.x, y: end(of: opened)), animated: false)
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(abs(opened.contentOffset.y - end(of: opened)) <= 1)

        path.threads = []
        try await Task.sleep(for: .seconds(1))
        path.threads = [scout.id]
        try await Task.sleep(for: .seconds(1))

        let reopened = try conversation()
        #expect(abs(reopened.contentOffset.y - end(of: reopened)) <= 1)
    }

    /// With the keyboard up, the message field keeps 8 points clear of it, and the conversation still
    /// ends 16 points above the field.
    @Test func theComposerSitsClearOfTheKeyboard() async throws {
        let hub = FakeHub()
        for index in 1..<40 { await hub.botSays(String(repeating: "Message \(index) says something. ", count: 1 + index % 4)) }
        let (chats, server) = try await paired(to: hub)
        defer { server.stop() }
        try await chats.reload()
        let scout = try #require(chats.agents.first)
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)

        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatView(chats: chats, threadID: scout.id) })
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))
        let field = try #require(Self.view(PastingTextView.self, in: window) { _ in true })
        // The simulator shows no keyboard, and SwiftUI does not make room for a posted notice of one,
        // so the field is measured from the edge the keyboard would take: the safe area's.
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        try await Task.sleep(for: .milliseconds(500))

        let keyboardTop = window.bounds.maxY - window.safeAreaInsets.bottom
        let conversation = try #require(Self.view(UIScrollView.self, in: window) { !($0 is UITextView) && $0.contentSize.height > window.bounds.height })
        // The editor includes the padding inside the glass around its text.
        let fieldBottom = field.convert(field.bounds, to: window).maxY
        let end = conversation.convert(conversation.bounds, to: window).maxY - conversation.adjustedContentInset.bottom

        #expect(abs(keyboardTop - fieldBottom - 8) < 1)
        #expect(abs(fieldBottom - ChatView.controlHeight - end - 16) < 1)
    }

    private static func view<V: UIView>(_ type: V.Type, in view: UIView, where test: (V) -> Bool) -> V? {
        if let match = view as? V, test(match) { return match }
        for subview in view.subviews { if let match = self.view(type, in: subview, where: test) { return match } }
        return nil
    }
}

@MainActor @Observable final class OpenChats {
    var threads: [UUID] = []
}

/// A list a conversation is opened from and left for, as the bots list does.
private struct ReopenedChat: View {
    let chats: HubChats
    @Bindable var path: OpenChats

    var body: some View {
        NavigationStack(path: $path.threads) {
            List { Text("Bots") }
                .navigationDestination(for: UUID.self) { ChatView(chats: chats, threadID: $0) }
        }
    }
}
