import AppKit
import AVFoundation
import BrowserBridge
import ComputerBridge
import Foundation
import HubCore
import HubLink
import NoodleCore
import NoodleRuntime
import XCTest
@testable import NoodleMCP

/// Noodle serving its own owner's devices: the bots already on the Mac, with nobody else to share them.
@MainActor final class PersonalHubTests: XCTestCase {
    private struct Fixture {
        let personal: PersonalHub
        let repository: WorkspaceRepository
        let device: HubPairing
        let computer: HubComputersTests.FakeComputer
        let browser: HubBrowsersTests.FakeBrowser
        let hubDirectory: URL
    }

    /// Only the harnesses in `installed` are on this Mac, whatever the machine running the test has.
    private func fixture(bots names: [String], runtime: AgentRuntimeCoordinator? = nil, installed: [String] = [],
                         models: [HarnessProvider: [HarnessModel]] = [:],
                         profiles named: [(HarnessProvider, String)] = []) async throws -> (Fixture, [AgentRecord]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-personal-hub-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        try repository.prepare()
        // Bots made in Noodle before it served anyone.
        let made = try names.map { try repository.createAgent(named: $0).agent }
        let home = root.appendingPathComponent("Home")
        for path in installed {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let runtime = runtime ?? {
            let runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(homeDirectory: home, applicationsDirectory: home,
                executableSearchDirectories: [], applicationBundleURL: home, managedHarnesses: repository.managedHarnesses))
            // Scripted, so no harness is ever run to ask for its models.
            runtime.scriptedModels = models
            runtime.refreshCapabilities()
            return runtime
        }()
        let computer = HubComputersTests.FakeComputer(), browser = HubBrowsersTests.FakeBrowser()
        let profiles = HarnessProfilesController(store: repository.harnessProfiles)
        for (provider, name) in named { _ = try profiles.create(provider: provider, named: name) }
        let personal = PersonalHub(name: "Studio", directory: root.appendingPathComponent("Remote"), repository: repository,
                                   runtime: runtime, applets: AppletController(),
                                   profiles: profiles, service: Self.service(),
                                   computer: { try computer.call($0) }, browser: { try browser.call($0) }, port: 0,
                                   localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await personal.start()
        addTeardownBlock { await MainActor.run { personal.stop() } }
        guard case .listening = personal.link.state else { throw XCTSkip("Could not listen: \(personal.link.state)") }
        let device = HubPairing(directory: root.appendingPathComponent("Phone"), deviceName: "iPhone")
        await device.join(personal.link.invite(personal.owner).url().absoluteString)
        XCTAssertNil(device.error)
        return (Fixture(personal: personal, repository: repository, device: device, computer: computer, browser: browser,
                        hubDirectory: root.appendingPathComponent("Remote")), made)
    }

    /// Noodle's own tool service, with a Keychain that holds no sign-ins.
    private static func service() -> MCPService {
        MCPService(credentials: NoPersonalCredentials(), oauth: MCPOAuth(), httpConfiguration: { .ephemeral })
    }

    /// This Mac is its owner's alone, so nothing is hosted on it, and Noodle's runtime is left alone.
    func testNothingIsHostedOnThisMac() async throws {
        let (runtime, _) = try fakeRuntime()
        let (f, _) = try await fixture(bots: [], runtime: runtime)
        let id = UUID()
        runtime.remoteAgentIDs = [id]
        do {
            _ = try await f.device.request(.host(.publish(id: UUID(), LinkBotDraft(name: "Alfred", provider: ""))))
            XCTFail("Hosted a bot on This Mac as a Hub")
        } catch {}
        guard case .hostedBots(let hosted) = try await f.device.request(.host(.bots)) else { return XCTFail("no answer") }
        XCTAssertEqual(hosted, [])
        XCTAssertEqual(runtime.remoteAgentIDs, [id])
        XCTAssertTrue(try f.repository.loadAgents().isEmpty)
    }

    /// A bot on the Mac shared through another Hub keeps its copies of those people's conversations
    /// beside Noodle's own; the owner's phone neither sees them nor can drop them.
    func testThePhoneLeavesConversationsKeptForAnotherHubAlone() async throws {
        let (f, made) = try await fixture(bots: ["Kai"])
        let guest = try f.repository.createGuestConversation(with: made[0], guest: ConversationGuest(id: UUID(), name: "Grace"))
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertEqual(bots.first?.sharedWith, [])
        XCTAssertNotEqual(bots.first?.conversationID, guest.id)
        _ = try? await f.device.request(.shareBot(id: made[0].id, people: []))
        XCTAssertTrue(try f.repository.loadConversations().contains { $0.id == guest.id })
        do {
            _ = try await f.device.request(.messagePage(LinkMessagePage(conversationID: guest.id, after: 0)))
            XCTFail("The phone read someone else's conversation")
        } catch {}
    }

    /// The phone shares a bot on the Mac with people on the Hubs the Mac joined, through Noodle, which
    /// keeps that sharing; only the Mac's own bots, never copies of bots kept on a Hub.
    func testThePhoneSharesABotThroughTheHubsTheMacJoined() async throws {
        let (runtime, _) = try fakeRuntime()
        let (f, made) = try await fixture(bots: ["Kai", "Eli"], runtime: runtime)
        let kai = made[0], eli = made[1], grace = UUID()
        // Eli is this Mac's copy of a bot kept on a Hub, hidden as This Mac as a Hub hides it in Noodle.
        runtime.remoteAgentIDs = [eli.id]
        f.personal.bots.isHidden = { [runtime] in runtime.remoteAgentIDs.contains($0) }
        var asked: [String] = []
        var studio = LinkHubSharing(id: "studio", name: "Studio", people: [LinkPerson(id: grace, name: "Grace")], sharedWith: [])
        f.personal.link.hubSharing = { id in
            asked.append("list \(id == kai.id ? "Kai" : "other")")
            return [studio]
        }
        f.personal.link.shareOnHub = { id, hub, people in
            asked.append("share \(id == kai.id ? "Kai" : "other") on \(hub) with \(people.count)")
            studio.sharedWith = people
            return [studio]
        }
        let listed = try await f.device.request(.hubSharing(botID: kai.id))
        XCTAssertEqual(listed, .hubSharing([studio]))
        let shared = try await f.device.request(.shareOnHub(botID: kai.id, hub: "studio", people: [grace]))
        XCTAssertEqual(shared, .hubSharing([LinkHubSharing(id: "studio", name: "Studio", people: [LinkPerson(id: grace, name: "Grace")],
                                                           sharedWith: [grace])]))
        for request in [LinkRequest.hubSharing(botID: eli.id), .shareOnHub(botID: eli.id, hub: "studio", people: []),
                        .hubSharing(botID: UUID())] {
            do {
                _ = try await f.device.request(request)
                XCTFail("Shared what is not the Mac's own bot: \(request)")
            } catch {}
        }
        XCTAssertEqual(asked, ["list Kai", "share Kai on studio with 1"])
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

    /// The owner's phone is offered what the Mac's bot editor offers: the installed harnesses, each
    /// with its profiles, and all of their models.
    func testAPhoneIsOfferedTheMacsHarnessesProfilesAndModels() async throws {
        let codex = ["gpt-5.5", "gpt-5.5-mini", "gpt-5.5-codex"].map {
            HarnessModel(id: $0, displayName: $0.uppercased(), description: "",
                         supportedEfforts: $0 == "gpt-5.5" ? [HarnessEffort(id: "low", description: ""), HarnessEffort(id: "xhigh", description: "")] : [],
                         defaultEffort: $0 == "gpt-5.5" ? "low" : "", isDefault: false)
        }
        let (f, _) = try await fixture(bots: [], installed: [".codex/packages/standalone/current/bin/codex", ".local/bin/fx"],
                                       models: [.codex: codex], profiles: [(.fx, "Work"), (.openCode, "Side")])
        guard case .status(let status) = try await f.device.request(.status) else { return XCTFail("no status") }
        // The Mac is only its owner's, so there is nobody to share a bot with.
        XCTAssertFalse(status.canShareBots)
        XCTAssertEqual(status.harnesses.map { [$0.providerName, $0.profileName ?? ""] },
                       [["Codex", ""], ["FX", ""], ["FX", "Work"]])
        XCTAssertEqual(status.harnesses.map(\.provider), ["codex", "fx", "fx"])
        XCTAssertFalse(status.harnesses.contains(where: \.restrictsModels))
        let lent = try XCTUnwrap(status.harnesses.first { $0.provider == HarnessProvider.codex.rawValue })
        XCTAssertEqual(lent.models.map(\.name), codex.map(\.displayName))
        XCTAssertEqual(lent.models.first?.efforts, [LinkEffort(id: "low", name: "Low"), LinkEffort(id: "xhigh", name: "Extra High")])
        XCTAssertEqual(lent.models.first?.defaultEffort, "low")
        XCTAssertEqual(lent.models.last?.efforts, [])
        XCTAssertNil(lent.models.last?.defaultEffort)
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

    /// A conversation's background is the Mac's, whichever device sets it. The phone fetches a
    /// small copy of a video, and the Mac hears when the phone changes it.
    func testThePhoneShowsAndSetsTheMacsBackgrounds() async throws {
        let (f, made) = try await fixture(bots: ["Eli"])
        let conversation = try XCTUnwrap(f.repository.loadConversations().first { $0.participantIDs == [made[0].id] })
        let events = try await f.device.subscribe()
        f.personal.bots.checkForChanges()
        // Once the Hub answers, it has the subscription.
        guard case .bots(let plain) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertEqual(plain.first?.background, LinkBackground())
        try f.repository.setBackground(conversationID: conversation.id, preset: .ocean)
        f.personal.bots.checkForChanges()
        var heard: LinkBackground?
        for try await event in events {
            if case .backgroundChanged(conversation.id, let background) = event { heard = background; break }
        }
        XCTAssertEqual(heard, LinkBackground(preset: "ocean"))
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertEqual(bots.first?.background, LinkBackground(preset: "ocean"))

        let movie = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-background-\(UUID()).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: movie) }
        try await Self.video(at: movie)
        let set = try f.repository.setBackground(conversationID: conversation.id, file: try await PreparedBackgroundFile.prepare(movie))
        guard case .bots(let listed) = try await f.device.request(.bots), let video = listed.first?.background else {
            return XCTFail("no background")
        }
        XCTAssertEqual(video.media, set.imageFilename)
        XCTAssertEqual(video.mediaKind, "video")
        let original = f.hubDirectory.appendingPathComponent("original.mov"), compact = f.hubDirectory.appendingPathComponent("compact.mp4")
        try await f.device.downloadBackground(try XCTUnwrap(video.media), of: conversation.id, compact: false, to: original)
        XCTAssertEqual(try Data(contentsOf: original),
                       try Data(contentsOf: XCTUnwrap(f.repository.backgroundImageURL(set, conversationID: conversation.id))))
        try await f.device.downloadBackground(try XCTUnwrap(video.media), of: conversation.id, compact: true, to: compact)
        let small = AVURLAsset(url: compact)
        let playable = try await small.load(.isPlayable), sound = try await small.loadTracks(withMediaType: .audio)
        XCTAssertTrue(playable)
        XCTAssertEqual(sound, [])
        let track = try await small.loadTracks(withMediaType: .video).first
        let size = try await XCTUnwrap(track).load(.naturalSize)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1280)
        // A background since replaced is not there to fetch.
        try f.repository.setBackground(conversationID: conversation.id, preset: nil)
        do {
            try await f.device.downloadBackground(try XCTUnwrap(video.media), of: conversation.id, compact: true, to: compact)
            XCTFail("Fetched a background that is gone")
        } catch {}

        var changed: UUID?
        f.personal.bots.onBackgroundChanged = { changed = $0 }
        guard case .background(let dusk) = try await f.device.request(.setBackground(
            LinkBackgroundChoice(conversationID: conversation.id, preset: "dusk"))) else { return XCTFail("no background") }
        XCTAssertEqual(dusk, LinkBackground(preset: "dusk"))
        XCTAssertEqual(try f.repository.loadBackground(conversationID: conversation.id).preset, .dusk)
        XCTAssertEqual(changed, conversation.id)

        let photo = f.hubDirectory.appendingPathComponent("photo.png")
        try Self.picture(at: photo)
        let uploaded = try await f.device.uploadBackground(photo, to: conversation.id)
        let kept = try f.repository.loadBackground(conversationID: conversation.id)
        XCTAssertEqual(uploaded.media, kept.imageFilename)
        XCTAssertEqual(kept.mediaKind, .image)
        XCTAssertNil(kept.preset)
        XCTAssertNotNil(try f.repository.backgroundImageURL(kept, conversationID: conversation.id).flatMap { NSImage(contentsOf: $0) })
    }

    /// Whatever a conversation's folder holds, such as a name that leaves it or a link out of it, a
    /// device never reads a file elsewhere on the Mac through its background.
    func testABackgroundNeverLeadsToAFileElsewhere() async throws {
        let (f, made) = try await fixture(bots: ["Eli"])
        let conversation = try XCTUnwrap(f.repository.loadConversations().first { $0.participantIDs == [made[0].id] })
        let folder = f.repository.conversationDirectory(id: conversation.id)
        let secret = f.hubDirectory.appendingPathComponent("secret.jpg")
        try Self.picture(at: secret)
        func name(_ background: ConversationBackground) throws {
            try JSONEncoder().encode(background).write(to: folder.appendingPathComponent("background.json"))
        }
        func fetch(_ media: String, compact: Bool) async -> Bool {
            let copy = f.hubDirectory.appendingPathComponent(UUID().uuidString)
            return (try? await f.device.downloadBackground(media, of: conversation.id, compact: compact, to: copy)) != nil
        }

        let outside = "../../../\(secret.lastPathComponent)"
        try name(ConversationBackground(imageFilename: outside, mediaKind: .image))
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertNil(bots.first?.background?.media)
        let fetchedOutside = await fetch(outside, compact: false)
        XCTAssertFalse(fetchedOutside)

        for kind in [BackgroundMediaKind.image, .video, .dynamicImage] {
            let link = "\(UUID().uuidString.lowercased()).\(kind == .video ? "mov" : "jpg")"
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Backgrounds"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Backgrounds/\(link)"), withDestinationURL: secret)
            try name(ConversationBackground(imageFilename: link, mediaKind: kind))
            let original = await fetch(link, compact: false), compact = await fetch(link, compact: true)
            XCTAssertFalse(original, "\(kind)")
            XCTAssertFalse(compact, "\(kind)")
        }
        // A folder that is itself a link out.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Backgrounds"))
        let elsewhere = f.hubDirectory.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let planted = "\(UUID().uuidString.lowercased()).jpg"
        try FileManager.default.copyItem(at: secret, to: elsewhere.appendingPathComponent(planted))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Backgrounds"), withDestinationURL: elsewhere)
        try name(ConversationBackground(imageFilename: planted, mediaKind: .image))
        let throughFolder = await fetch(planted, compact: false)
        XCTAssertFalse(throughFolder)
    }

    /// A short silent movie, as a person might pick for a background.
    static func video(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<12 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(index * 15), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 12)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    static func picture(at url: URL) throws {
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.orange.setFill()
            rect.fill()
            return true
        }
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    /// Reading on the Mac reads on the phone, and reading on the phone tells the Mac.
    func testReadingIsSharedBetweenTheMacAndThePhone() async throws {
        let (f, made) = try await fixture(bots: ["Eli"])
        let conversation = try XCTUnwrap(f.repository.loadConversations().first { $0.participantIDs == [made[0].id] })
        _ = try f.repository.sendAgentMessage(agentID: made[0].id, conversationID: conversation.id, body: "Morning")
        // As kept, which is to the second.
        let morning = try XCTUnwrap(f.repository.loadMessages(conversationID: conversation.id).last)

        f.personal.markRead(conversation: conversation.id)
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        XCTAssertEqual(bots.first?.readUpTo, morning.createdAt)

        let evening = ChatMessage(id: UUID(), conversationID: conversation.id, author: .agent(made[0].id), body: "Evening",
                                  createdAt: morning.createdAt.addingTimeInterval(60), delivery: .delivered)
        try f.repository.append(evening)
        var read: (conversation: UUID, upTo: Date)?
        f.personal.onRead = { read = ($0, $1) }
        _ = try await f.device.request(.markRead(LinkReadMark(conversationID: conversation.id, messageID: evening.id)))
        XCTAssertEqual(read?.conversation, conversation.id)
        XCTAssertEqual(read?.upTo, evening.createdAt)
    }

    /// The Mac's own pins are the phone's: pinning on the phone pins on the Mac, and pinning on the Mac reaches the phone, in order.
    func testPinsAreTheMacsOwn() async throws {
        let (f, made) = try await fixture(bots: ["Eli", "Ada"])
        let conversations = try f.repository.loadConversations()
        let eli = try XCTUnwrap(conversations.first { $0.participantIDs == [made[0].id] })
        let ada = try XCTUnwrap(conversations.first { $0.participantIDs == [made[1].id] })
        var edited = 0
        f.personal.onPinsEdited = { edited += 1 }

        _ = try await f.device.request(.pin(LinkPin(conversationID: eli.id, pinned: true)))
        XCTAssertEqual(try f.repository.loadPinnedConversationIDs(), [eli.id])
        XCTAssertEqual(edited, 1)

        let events = try await f.device.subscribe()
        // Once the Hub answers, it has the subscription.
        _ = try await f.device.request(.bots)
        try f.repository.savePinnedConversationIDs([ada.id, eli.id])
        f.personal.pinsChanged()
        var heard: Set<UUID> = []
        for try await event in events {
            if case .pinChanged(let id, _) = event { heard.insert(id) }
            if heard.contains(ada.id) { break }
        }
        guard case .bots(let bots) = try await f.device.request(.bots) else { return XCTFail("no bots") }
        let pinned = bots.filter { $0.pinnedAt != nil }.sorted { $0.pinnedAt! < $1.pinnedAt! }.map(\.conversationID)
        XCTAssertEqual(pinned, [ada.id, eli.id])
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

    private struct FeminineNames: VoicePresentationGuessing {
        func presentation(forName name: String) async -> VoicePresentation? { .feminine }
    }

    /// A phone calls a bot on the Mac: the Mac starts the call with the bot's voice, passes back
    /// what is said, keeps the call in the conversation, and hears what is typed meanwhile.
    func testAPhoneCallsABotAndTheHubKeepsTheCallInItsConversation() async throws {
        let (runtime, processes) = try fakeRuntime()
        let (f, _) = try await fixture(bots: [], runtime: runtime)
        f.personal.bots.voiceGuesser = FeminineNames()
        let (agent, process) = try startedBot(f, in: runtime, processes)
        let quiet = try f.repository.createAgent(named: "Eli", harnessIdentifier: "claude-code").agent
        guard case .bots(let bots) = try await f.device.request(.bots),
              let kai = bots.first(where: { $0.id == agent.id }), let eli = bots.first(where: { $0.id == quiet.id }) else {
            return XCTFail("no bots")
        }
        XCTAssertTrue(kai.canCall)
        XCTAssertFalse(eli.canCall, "Its harness has no voices")

        let refused = try await f.device.channel(.startCall(LinkCallStart(conversationID: eli.conversationID, offer: "offer-sdp")))
        guard case .ended(let reason)? = try await firstCallEvent(on: refused) else { return XCTFail("a bot without voices took a call") }
        XCTAssertNotNil(reason)

        let channel = try await f.device.channel(.startCall(LinkCallStart(conversationID: kai.conversationID, offer: "offer-sdp")))
        await waitUntil { process.callRequests.count == 1 }
        let request = try XCTUnwrap(process.callRequests.first)
        XCTAssertEqual(request.offer, "offer-sdp")
        XCTAssertEqual(request.conversationID, kai.conversationID)
        XCTAssertEqual(request.personName, f.personal.owner.name)
        XCTAssertEqual(request.voice, "juniper", "A bot without a voice gets one matching its name")
        XCTAssertEqual(try f.repository.loadAgentVoice(agent), "juniper")

        process.callEvents?(.answer("answer-sdp"))
        process.callEvents?(.started)
        process.callEvents?(.line(.init(.person, "Can you check the build?")))
        var received: [LinkCallEvent] = []
        for try await frame in channel.frames {
            received.append(try XCTUnwrap(LinkCallEvent(frame)))
            if received.count == 3 { break }
        }
        XCTAssertEqual(received.prefix(2), [.answer("answer-sdp"), .started])
        guard case .line(let line) = received.last else { return XCTFail("no line") }
        XCTAssertEqual(line.speaker, .you)
        XCTAssertEqual(line.text, "Can you check the build?")
        XCTAssertNotNil(line.at)

        let cards = { try f.repository.loadMessages(conversationID: kai.conversationID).filter { $0.call != nil } }
        XCTAssertEqual(try cards().count, 1)
        XCTAssertNil(try cards().first?.call?.endedAt)

        _ = try await f.device.request(.send(LinkOutgoingMessage(conversationID: kai.conversationID, id: UUID(), body: "Here is the log")))
        XCTAssertEqual(process.callTexts, [VoiceCallDocumentation.typedMessage(body: "Here is the log", attachmentNames: [])])

        channel.cancel()
        await waitUntil { process.callEnds == 1 }
        XCTAssertEqual(process.callEnds, 1)
        await waitUntil { (try? cards().first?.call?.endedAt) != nil }
        let card = try XCTUnwrap(cards().first)
        XCTAssertNotNil(card.call?.endedAt)
        XCTAssertEqual(card.call?.lines.map(\.text), ["Can you check the build?"])
        guard case .messages(let page) = try await f.device.request(.messages(conversationID: kai.conversationID, after: 0)) else {
            return XCTFail("no messages")
        }
        XCTAssertEqual(page.messages.first { $0.id == card.id }?.call?.lines.map(\.text), ["Can you check the build?"])
    }

    private func firstCallEvent(on channel: LinkChannel) async throws -> LinkCallEvent? {
        for try await frame in channel.frames { return LinkCallEvent(frame) }
        return nil
    }

    private func startedBot(_ f: Fixture, in runtime: AgentRuntimeCoordinator, _ processes: () -> [FakeProcess]) throws -> (AgentRecord, FakeProcess) {
        let made = try f.repository.createAgent(named: "Kai", harnessIdentifier: "codex").agent
        // As Noodle runs it: read back from its library.
        let agent = try XCTUnwrap(f.repository.loadAgents().first { $0.id == made.id })
        runtime.start(agent: agent, repository: f.repository)
        return (agent, try XCTUnwrap(processes().last))
    }

    /// As in Noodle's sidebar: Kick restarts a failed bot at once, through the Mac's own runtime.
    func testAPhoneKicksAFailedBotThroughTheMacsRuntime() async throws {
        let (runtime, processes) = try fakeRuntime()
        let (f, _) = try await fixture(bots: [], runtime: runtime)
        let (agent, first) = try startedBot(f, in: runtime, processes)
        first.set(.failed)

        let answer = try await f.device.request(.kick(botID: agent.id))
        XCTAssertEqual(answer, .done)
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(processes().count, 2, "Kick starts the bot again in Noodle's runtime, not another")
        XCTAssertEqual(runtime.snapshot(for: agent.id).phase, .ready)
    }

    /// A failure Noodle asks about first is asked about on the phone too, in Noodle's words,
    /// and only the confirmation restarts the bot, once.
    func testAPhoneConfirmsAKickNoodleWouldAskAbout() async throws {
        let (runtime, processes) = try fakeRuntime()
        let (f, _) = try await fixture(bots: [], runtime: runtime)
        let (agent, first) = try startedBot(f, in: runtime, processes)
        first.set(.failed, failure: .safetyStop)

        guard case .kickConfirmation(let confirmation) = try await f.device.request(.kick(botID: agent.id)) else {
            return XCTFail("no confirmation")
        }
        XCTAssertEqual(confirmation.title, "Safeguards stopped Kai")
        XCTAssertTrue(confirmation.message.hasPrefix("The model's safeguards stopped a response."))
        XCTAssertEqual(confirmation.confirmTitle, "Resume")
        XCTAssertTrue(confirmation.offersNewSession)
        XCTAssertEqual(first.stops, 0, "Asking must leave the bot alone")

        let confirmed = try await f.device.request(.confirmKick(botID: agent.id, confirmationID: confirmation.id))
        XCTAssertEqual(confirmed, .done)
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(processes().count, 2)
        let again = try await f.device.request(.confirmKick(botID: agent.id, confirmationID: confirmation.id))
        XCTAssertEqual(again, .done)
        XCTAssertEqual(processes().count, 2, "A confirmation works once")
    }

    /// As in Noodle's sidebar: New Session is there whatever the bot is doing, but not for another Hub's bot.
    func testAPhoneStartsANewSession() async throws {
        let (runtime, processes) = try fakeRuntime()
        let (f, _) = try await fixture(bots: [], runtime: runtime)
        let (agent, first) = try startedBot(f, in: runtime, processes)

        let answer = try await f.device.request(.newSession(botID: agent.id))
        XCTAssertEqual(answer, .done)
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(processes().count, 2)

        f.personal.bots.isHidden = { $0 == agent.id }
        do {
            _ = try await f.device.request(.newSession(botID: agent.id))
            XCTFail("another Hub's bot was restarted")
        } catch {}
        XCTAssertEqual(processes().count, 2)
    }

    /// As Edit Bot in Noodle: a model or effort changed on the phone is what the running bot uses next.
    func testAPhoneEditingABotRestartsItWithTheNewSettings() async throws {
        let (runtime, processes) = try fakeRuntime()
        let (f, _) = try await fixture(bots: [], runtime: runtime)
        let (agent, first) = try startedBot(f, in: runtime, processes)

        let draft = LinkBotDraft(name: "Kai", provider: "codex", model: "gpt-5.5", reasoningEffort: "high")
        _ = try await f.device.request(.updateBot(id: agent.id, draft))

        XCTAssertEqual(first.stops, 1, "The bot kept running with its old settings")
        let running = try XCTUnwrap(processes().last)
        XCTAssertEqual(running.configuration.modelIdentifier, "gpt-5.5")
        XCTAssertEqual(running.configuration.reasoningEffort, "high")
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

    /// The phone makes, changes, assigns and deletes the Mac's own tools, computers and browsers:
    /// the ones Noodle keeps beside its bots, not a copy only devices see.
    func testAPhoneManagesTheMacsOwnToolsComputersAndBrowsers() async throws {
        let (f, made) = try await fixture(bots: ["Kai"])
        let kai = made[0].id, root = f.repository.rootURL
        var edits = 0
        f.personal.onToolsEdited = { edits += 1 }

        let notes = LinkConnectionDraft(name: "Notes", endpoint: URL(string: "https://example.com/mcp")!)
        _ = try await f.device.request(.saveConnection(notes))
        _ = try await f.device.request(.assignConnections(botID: kai, connectionIDs: [notes.id]))
        XCTAssertEqual(try MCPRegistry.load(root: root).assigned(to: kai).map(\.name), ["Notes"])

        guard case .browser(let work) = try await f.device.request(.createBrowser(LinkBrowserDraft(name: "Work"))) else {
            return XCTFail("no browser")
        }
        _ = try await f.device.request(.assignBrowsers(botID: kai, browserIDs: [work.id]))
        guard case .browsers(let browsers) = try await f.device.request(.browsers) else { return XCTFail("no browsers") }
        XCTAssertEqual(browsers.map(\.botIDs), [[kai]])

        // Made in Noodle Computer on the Mac, then given to Kai from the phone.
        var create = ComputerRequest(.create)
        create.computer = ComputerDraft(template: "ubuntu", name: "Bench")
        let bench = try XCTUnwrap(try f.computer.call(create).computers?.first)
        guard case .computers(let listed) = try await f.device.request(.computers) else { return XCTFail("no computers") }
        XCTAssertEqual(listed.map(\.id), [bench.id])
        _ = try await f.device.request(.assignComputers(botID: kai, computerIDs: [bench.id]))
        _ = try await f.device.request(.updateComputer(id: bench.id, LinkComputerDraft(template: "ubuntu", name: "Workbench")))
        guard case .computers(let computers) = try await f.device.request(.computers) else { return XCTFail("no computers") }
        XCTAssertEqual(computers.map(\.name), ["Workbench"])
        XCTAssertEqual(computers.map(\.botIDs), [[kai]])
        _ = try await f.device.request(.deleteBrowser(id: work.id))
        guard case .browsers(let left) = try await f.device.request(.browsers) else { return XCTFail("no browsers") }
        XCTAssertTrue(left.isEmpty)

        // Kept in Noodle's own files, beside its bots, where its Settings and tool broker read them.
        // (Their contents are not read back: this macOS refuses to reopen protected files in tests.)
        for file in ["MCP/connections.json", "browsers.json", "computers.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path), file)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.hubDirectory.appendingPathComponent(file).path), file)
        }
        XCTAssertGreaterThan(edits, 0, "Noodle was not told to read its tools again")
    }

    /// What Noodle changed on the Mac after the phone joined is what the phone sees and changes,
    /// and a change from the phone keeps it.
    func testThePhoneWorksOnWhatNoodleChangedMeanwhile() async throws {
        let (f, made) = try await fixture(bots: ["Kai"])
        let kai = made[0].id, root = f.repository.rootURL
        // Saved in Noodle's Settings, as its tool controller does.
        var registry = try MCPRegistry.load(root: root)
        let notes = try MCPConnectionRecord(name: "Notes", endpoint: URL(string: "https://example.com/notes")!)
        registry.connections.append(notes)
        try registry.assign([notes.id], to: kai)
        try registry.save(root: root)

        guard case .connections(let listed) = try await f.device.request(.connections) else { return XCTFail("no connections") }
        XCTAssertEqual(listed.map(\.id), [notes.id])
        XCTAssertEqual(listed.first?.botIDs, [kai])

        let calendar = LinkConnectionDraft(name: "Calendar", endpoint: URL(string: "https://example.com/calendar")!)
        _ = try await f.device.request(.saveConnection(calendar))
        let saved = try MCPRegistry.load(root: root)
        XCTAssertEqual(Set(saved.connections.map(\.name)), ["Notes", "Calendar"])
        XCTAssertEqual(saved.assigned(to: kai).map(\.id), [notes.id])
    }

    /// Noodle's file cannot be read for a while, as when a locked Mac refuses a protected file.
    private func unreadable(_ file: URL, while body: () async throws -> Void) async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        try await body()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// A computer Noodle gave a bot after the phone joined stays given when the Mac cannot read
    /// Noodle's file back while the phone lists computers.
    func testAComputerNoodleAssignedSurvivesAnUnreadableFile() async throws {
        let (f, made) = try await fixture(bots: ["Kai"])
        let kai = made[0].id, file = f.repository.rootURL.appendingPathComponent("computers.json")
        var create = ComputerRequest(.create)
        create.computer = ComputerDraft(template: "ubuntu", name: "Bench")
        let bench = try XCTUnwrap(try f.computer.call(create).computers?.first)
        var saved = ComputerAssignments()
        saved.computers = [bench]
        saved.agents[kai.uuidString] = [bench.id]
        try JSONEncoder().encode(saved).write(to: file)

        try await unreadable(file) { _ = try? await f.device.request(.computers) }

        let after = try JSONDecoder().decode(ComputerAssignments.self, from: Data(contentsOf: file))
        XCTAssertEqual(after.assigned(to: kai), [bench.id])
    }

    func testABrowserNoodleAssignedSurvivesAnUnreadableFile() async throws {
        let (f, made) = try await fixture(bots: ["Kai"])
        let kai = made[0].id, file = f.repository.rootURL.appendingPathComponent("browsers.json")
        var create = BrowserRequest(.create)
        create.profile = BrowserDraft(name: "Work")
        let work = try XCTUnwrap(try f.browser.call(create).browser)
        var saved = BrowserAssignments()
        saved.browsers = [work]
        saved.agents[kai.uuidString] = [work.id]
        try JSONEncoder().encode(saved).write(to: file)

        try await unreadable(file) { _ = try? await f.device.request(.browsers) }

        let after = try JSONDecoder().decode(BrowserAssignments.self, from: Data(contentsOf: file))
        XCTAssertEqual(after.assigned(to: kai), [work.id])
    }

    func testAConnectionNoodleAssignedSurvivesAnUnreadableFile() async throws {
        let (f, made) = try await fixture(bots: ["Kai"])
        let kai = made[0].id, root = f.repository.rootURL
        var registry = MCPRegistry()
        let notes = try MCPConnectionRecord(name: "Notes", endpoint: URL(string: "https://example.com/notes")!)
        registry.connections.append(notes)
        try registry.assign([notes.id], to: kai)
        try registry.save(root: root)

        let calendar = LinkConnectionDraft(name: "Calendar", endpoint: URL(string: "https://example.com/calendar")!)
        try await unreadable(root.appendingPathComponent("MCP/connections.json")) {
            _ = try? await f.device.request(.saveConnection(calendar))
        }

        XCTAssertEqual(try MCPRegistry.load(root: root).assigned(to: kai).map(\.id), [notes.id])
    }

    /// It is the owner's own Mac: there is nobody else to add.
    func testNobodyElseCanBeAdded() async throws {
        let (f, _) = try await fixture(bots: [])
        XCTAssertThrowsError(try f.personal.access.addUser(named: "Bob"))
        XCTAssertEqual(f.personal.access.users.count, 1)
    }

    /// On a personal Mac everything is its owner's own: no bot, computer or browser is told whom it is for.
    func testAPersonalMacNamesNoOwners() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-personal-hub-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        try repository.prepare()
        let bot = try repository.createAgent(named: "Kai").agent
        let runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(managedHarnesses: repository.managedHarnesses))
        let personal = PersonalHub(name: "Studio", directory: root.appendingPathComponent("Remote"), repository: repository,
                                   runtime: runtime, applets: AppletController(),
                                   profiles: HarnessProfilesController(store: repository.harnessProfiles), service: Self.service(), port: 0)
        personal.bots.synchronizeOwners()
        try personal.access.rename(personal.owner, to: "Someone Else")
        personal.bots.synchronizeOwners()
        XCTAssertNil(try repository.loadAgentOwner(bot))

        let computer = HubComputersTests.FakeComputer(), browser = HubBrowsersTests.FakeBrowser()
        let tools = ToolProviderRegistry(), assignments = ToolAssignmentStore()
        let computers = HubComputers(root: root, access: personal.access, tools: tools, assignments: assignments, call: { try computer.call($0) })
        let browsers = HubBrowsers(root: root, access: personal.access, tools: tools, assignments: assignments, call: { try browser.call($0) })
        let madeComputer = try await computers.create(ComputerDraft(template: "ubuntu", name: "Bench"), for: personal.owner)
        let madeBrowser = try await browsers.create(BrowserDraft(name: "Work"), for: personal.owner)
        await computers.refresh()
        await browsers.refresh()
        XCTAssertNil(computer.owner(of: madeComputer.id))
        XCTAssertNil(browser.owner(of: madeBrowser.id))
    }

    /// Noodle passes its own Applet controller to This Mac as a Hub. Noodle's broker serves
    /// Noodle's bots the applet tool; the Hub it serves devices with must not take that over.
    func testThisMacAsAHubLeavesNoodlesAppletToolAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        try repository.prepare()
        let bot = try repository.createAgent(named: "Kai").agent
        let applets = AppletController(isInstalled: { true })
        var published: [[UUID: Set<String>]] = []
        applets.onGrantsChange = { published.append($0) }
        let runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(managedHarnesses: repository.managedHarnesses))
        _ = PersonalHub(name: "Studio", directory: root.appendingPathComponent("Remote"), repository: repository,
                        runtime: runtime, applets: applets,
                        profiles: HarnessProfilesController(store: repository.harnessProfiles), service: Self.service(), port: 0)
        applets.start(agents: [bot])
        defer { applets.start(agents: []) }
        XCTAssertEqual(published, [[bot.id: [AppletToolGrant.id]]])
    }
}

/// A Keychain with no sign-ins, that takes none.
private final class NoPersonalCredentials: MCPCredentialStorage, @unchecked Sendable {
    func load(_ id: UUID) throws -> MCPCredentials? { nil }
    func save(_ credentials: MCPCredentials, id: UUID) { XCTFail("These tests must never authorize an account") }
    func remove(_ id: UUID) throws {}
}
