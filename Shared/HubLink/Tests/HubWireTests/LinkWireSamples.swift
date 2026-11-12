#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
@testable import HubWire

/// One message as the link carries it: how this build encodes it, and whether decoding the golden
/// JSON gives the same value back. Nil from `mismatch` means it does.
struct LinkWireSample {
    let label: String
    let encode: () throws -> Data
    let mismatch: (Data) throws -> String?

    static func request(_ label: String, _ request: LinkRequest) -> LinkWireSample {
        LinkWireSample(label: "request.\(label)", encode: { try LinkProtocol.encode(request) }) { data in
            let decoded = try LinkProtocol.decode(data).get()
            return decoded == request ? nil : "\(decoded)"
        }
    }

    static func host(_ label: String, _ request: LinkHostRequest) -> LinkWireSample {
        Self.request("host.\(label)", .host(request))
    }

    static func response(_ label: String, _ response: LinkResponse) -> LinkWireSample {
        LinkWireSample(label: "response.\(label)", encode: { LinkProtocol.encode(response) }) { data in
            let decoded = try LinkProtocol.decodeResponse(data)
            return decoded == response ? nil : "\(decoded)"
        }
    }

    static func event(_ label: String, _ event: LinkEvent) -> LinkWireSample {
        LinkWireSample(label: "event.\(label)", encode: { LinkProtocol.encode(event) }) { data in
            let decoded = LinkProtocol.decodeEvent(data)
            return decoded == event ? nil : "\(String(describing: decoded))"
        }
    }

    /// A value sent on its own, with the link's encoder and decoder.
    static func value<T: Codable & Equatable>(_ label: String, _ value: T) -> LinkWireSample {
        LinkWireSample(label: label, encode: { try LinkProtocol.encoder.encode(value) }) { data in
            let decoded = try LinkProtocol.decoder.decode(T.self, from: data)
            return decoded == value ? nil : "\(decoded)"
        }
    }

    static func callEvent(_ label: String, _ event: LinkCallEvent) -> LinkWireSample {
        LinkWireSample(label: "callEvent.\(label)", encode: { event.encoded }) { data in
            let decoded = LinkCallEvent(data)
            return decoded == event ? nil : "\(String(describing: decoded))"
        }
    }

    /// The caller sealed into a ringing push, which uses a plain encoder.
    static func caller(_ label: String, _ caller: LinkCallPushCaller) -> LinkWireSample {
        LinkWireSample(label: "callPushCaller.\(label)", encode: { try JSONEncoder().encode(caller) }) { data in
            let decoded = try JSONDecoder().decode(LinkCallPushCaller.self, from: data)
            return decoded == caller ? nil : "\(decoded)"
        }
    }

    /// The JSON inside an invitation's link: what `url()` carries, and what `init(text:)` reads back.
    static func invitationLink(_ label: String, _ invitation: LinkInvitation) -> LinkWireSample {
        LinkWireSample(label: "invitationLink.\(label)", encode: {
            let url = invitation.url()
            let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "i" }?.value
            guard url.absoluteString.hasPrefix("noodle://join-hub?i="), let code, let data = Data(base64URL: code) else {
                throw LinkError("Unexpected invitation link \(url)")
            }
            return data
        }) { data in
            let decoded = try LinkInvitation(text: "noodle://join-hub?i=\(data.base64URL)")
            return decoded == invitation ? nil : "\(decoded)"
        }
    }
}

/// Fixed values, so the same build always encodes the same bytes.
enum LinkWireSamples {
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))! }
    static func date(_ offset: TimeInterval = 0) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + offset) }

    static let hubKey = LinkPublicKey(try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32)).publicKey)
    static let deviceKey = LinkPublicKey(try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x02, count: 32)).publicKey)
    static let joinKey = Data(repeating: 0x03, count: 32)
    static let digest = String(repeating: "ab", count: 32)
    static let picture = Data([0x89, 0x50, 0x4E, 0x47])

    // MARK: Building blocks

    static var fullDraft: LinkBotDraft {
        var draft = LinkBotDraft(name: "Ada", provider: "claude", profile: id(0x20), model: "opus", reasoningEffort: "high",
                                 publicDescription: "Helps with research.", backstory: "Grew up in a library.",
                                 avatarSymbolName: "book", avatarColorIndex: 4, avatarImageData: picture)
        draft.avatarImageDigest = digest
        draft.voice = "marin"
        draft.imageGeneration = true
        return draft
    }

    static let minimalDraft = LinkBotDraft(name: "Bo", provider: "codex")

    static let background = LinkBackground(preset: "sunset", media: "\(id(0x30).uuidString).jpg", mediaKind: "image")

    static let pause = LinkBotPause(summary: "Paused: plan limit", until: date(3600), detail: "The plan's weekly limit was reached.",
                                    kickable: true)

    static let tasks = [
        LinkTask(id: id(0x40), title: "Write the report", state: .open, conversationID: id(0x11), updatedAt: date(10)),
        LinkTask(id: id(0x41), title: "Review the draft", state: .waiting, waitingOn: .you, note: "Needs your eyes",
                 conversationID: id(0x11), updatedAt: date(20)),
        LinkTask(id: id(0x42), title: "Ask Bo", state: .waiting, waitingOn: .bot(id(0x02)), conversationID: id(0x12), updatedAt: date(30)),
    ]

    static var fullBot: LinkBot {
        LinkBot(id: id(0x01), conversationID: id(0x11), draft: fullDraft, createdAt: date(), phase: .ready, readUpTo: date(100),
                status: "Reading papers", archivedAt: date(200), background: background, sharedWith: [id(0x50), id(0x51)],
                owner: nil, canCall: true, pinnedAt: date(300), pause: pause, suspendedUntil: date(400), tasks: tasks)
    }

    static let minimalBot = LinkBot(id: id(0x02), conversationID: id(0x12), draft: minimalDraft, createdAt: date())

    static let sharedBot = LinkBot(id: id(0x03), conversationID: id(0x13),
                                   draft: LinkBotDraft(name: "Cy", provider: "", publicDescription: "Shared with you."),
                                   createdAt: date(), phase: .working, owner: "Dee", canCall: true)

    static let fullGroup = LinkGroup(id: id(0x60), draft: LinkGroupDraft(name: "Team", publicDescription: "All of us",
                                                                         botIDs: [id(0x01), id(0x02)]),
                                     createdAt: date(), readUpTo: date(10), archivedAt: date(20), background: background,
                                     pinnedAt: date(30), notifications: .mentions)
    static let minimalGroup = LinkGroup(id: id(0x61), draft: LinkGroupDraft(name: "Pair", botIDs: [id(0x01)]), createdAt: date())

    static let annotation = LinkAnnotation(version: 1, sourceAttachmentID: id(0x71), sourceFilename: "plan.pdf",
                                           sourceMessageID: id(0x81), quote: "the plan", comment: "Shorter, please.",
                                           region: .init(x: 0.25, y: 0.5, width: 0.125, height: 0.375))

    static let card = LinkCardInfo(title: "Counter", detail: "A game", image: Data([1, 2, 3]), symbol: "square.grid.2x2", colour: 2,
                                   icon: Data([4, 5]), capturedAt: date(50), isGame: true)

    static let fullAttachment = LinkAttachment(
        id: id(0x70), filename: "voice.m4a", mediaType: "audio/mp4", byteCount: 2048,
        voice: LinkVoice(transcript: "Hello there", duration: 2.5, waveform: [0, 0.25, 0.5, 1], localeIdentifier: "en_GB"),
        annotation: annotation, url: URL(string: "https://example.com/a?b=c")!, card: card,
        pixelSize: LinkPixelSize(width: 640, height: 480)!)
    static let minimalAttachment = LinkAttachment(id: id(0x71), filename: "plan.pdf", mediaType: "application/pdf", byteCount: 10)
    static let annotationOnly = LinkAttachment(id: id(0x72), filename: "comment.png", mediaType: "image/png", byteCount: 99,
                                               annotation: LinkAnnotation(version: 1, sourceAttachmentID: id(0x71),
                                                                          sourceFilename: "plan.pdf", comment: "Nice"))
    static let voiceOnly = LinkAttachment(id: id(0x73), filename: "memo.m4a", mediaType: "audio/mp4", byteCount: 5,
                                          voice: LinkVoice(transcript: nil, duration: 1, waveform: [], localeIdentifier: nil))

    static let callRecord = LinkCallRecord(botID: id(0x01), endedAt: date(600), lines: [
        LinkCallLine(speaker: .you, text: "Hi", at: date(500)),
        LinkCallLine(speaker: .bot, text: "Hello", at: nil),
    ], unanswered: .declined, reason: "A reminder")

    static let fullMessage = LinkMessage(
        id: id(0x80), conversationID: id(0x11), author: .bot(id(0x01)), body: "Here it is.", createdAt: date(), delivered: true,
        attachments: [fullAttachment, minimalAttachment, annotationOnly, voiceOnly],
        reactions: [LinkReaction(author: .you, emoji: "👍"), LinkReaction(author: .bot(id(0x02)), emoji: "🎉"),
                    LinkReaction(author: .system, emoji: "!")],
        call: callRecord, task: LinkTaskReference(id: id(0x40), botID: id(0x01), title: "Write the report"))
    static let minimalMessage = LinkMessage(id: id(0x81), conversationID: id(0x11), author: .you, body: "", createdAt: date(1),
                                            delivered: false)
    static let systemMessage = LinkMessage(id: id(0x82), conversationID: id(0x11), author: .system, body: "Call started",
                                           createdAt: date(2), delivered: true, call: LinkCallRecord(botID: id(0x01)))

    static var fullConnection: LinkConnection {
        var connection = LinkConnection(draft: connectionDraft, iconData: picture, botIDs: [id(0x01)], signedIn: true,
                                        problem: "Token expired")
        connection.iconDigest = digest
        return connection
    }
    static let connectionDraft = LinkConnectionDraft(id: id(0x90), name: "Linear", endpoint: URL(string: "https://mcp.linear.app/sse")!,
                                                     description: "Issues", instructions: "Use for tickets.")
    static let minimalConnection = LinkConnection(draft: LinkConnectionDraft(id: id(0x91), name: "Bare",
                                                                             endpoint: URL(string: "https://example.com/mcp")!))

    static var fullComputer: LinkComputer {
        var computer = LinkComputer(id: id(0xA0), name: "Box", description: "Linux box", kind: "linux", state: "running",
                                    symbol: "desktopcomputer", colour: 3, icon: picture, botIDs: [id(0x01)])
        computer.iconDigest = digest
        return computer
    }
    static let minimalComputer = LinkComputer(id: id(0xA1), name: "Mac", kind: "mac", state: "stopped", symbol: "laptopcomputer")

    static var fullBrowser: LinkBrowser {
        var browser = LinkBrowser(id: id(0xB0), name: "Work", description: "Signed in to work", symbol: "briefcase", colour: 5,
                                  icon: picture, paused: true, botIDs: [id(0x01), id(0x02)])
        browser.iconDigest = digest
        return browser
    }
    static let minimalBrowser = LinkBrowser(id: id(0xB1), name: "Plain")

    static let avatar = LinkAvatar(symbol: "star", colour: 3, image: picture, imageDigest: digest)

    static let fullUser = LinkUser(id: id(0xC0), name: "Ada", plan: id(0xC9), canPairDevices: true, isAdmin: true, devices: [
        LinkUserDevice(id: id(0xD0), name: "iPhone", paired: date(), lastSeen: date(1000), isConnected: true),
        LinkUserDevice(id: id(0xD1), name: "Mac", paired: date(5), lastSeen: nil, isConnected: false),
    ], avatar: avatar, isSuspended: true)
    static let minimalUser = LinkUser(id: id(0xC1), name: "Bo", plan: id(0xC9), canPairDevices: false, isAdmin: false, devices: [])

    static let fullStatus = LinkStatus(
        hubName: "Home Hub", userName: "Ada", planName: "Family",
        harnesses: [
            LinkHarness(provider: "claude", providerName: "Claude", profile: id(0xE0), profileName: "Work",
                        models: [LinkModel(id: "opus", name: "Opus", efforts: [LinkEffort(id: "high", name: "High"),
                                                                               LinkEffort(id: "low", name: "Low")],
                                           defaultEffort: "high"),
                                 LinkModel(id: "haiku", name: "Haiku")],
                        restrictsModels: true,
                        voices: [LinkCallVoice(id: "marin", name: "Marin", presentation: .feminine),
                                 LinkCallVoice(id: "cedar", name: "Cedar", presentation: .masculine)]),
            LinkHarness(provider: "codex", providerName: "Codex", profileName: nil),
        ],
        endpoints: [LinkEndpoint(host: "hub.local", port: 38_415), LinkEndpoint(host: "fd7a:115c:a1e0::1", port: 38_416)],
        protocolVersion: 1, canPairDevices: true, isAdmin: true, canShareBots: true, userID: id(0xC0), avatar: avatar,
        imageModel: "flux", keepsAnnotations: true, signsInToBrowsers: true, ringsThroughPush: true, callPushExpiresAt: date(86_400),
        explainsPauses: true, mutesGroups: true, notifiesMentions: true, groupNotifications: .mentions, suspendsBots: true,
        stopsBots: true)
    static let minimalStatus = LinkStatus(hubName: "Hub", userName: "", planName: "", harnesses: [], endpoints: [])

    static let invitation = LinkInvitation(hubName: "Home Hub", hubKey: hubKey,
                                           endpoints: [LinkEndpoint(host: "hub.local", port: 38_415)],
                                           userName: "Ada", joinKey: joinKey, expires: date(900))

    static let gamepad = Gamepad(pads: [Gamepad.Pad(left: "left", right: "right", up: "up", down: "down", stick: true),
                                        Gamepad.Pad(left: "a", right: "d")],
                                 buttons: [Gamepad.Button(key: "space", label: "Jump"), Gamepad.Button(key: "x")],
                                 menu: "escape")

    static let callGrant = CallGrant(sealed: Data([1, 2, 3]), deviceKey: deviceKey.x963, hubKey: hubKey.x963,
                                     expiresAt: 1_701_209_600, signature: Data(repeating: 0x5A, count: 64))

    static let signInForm = LinkSignInForm(token: id(0xF0), host: "accounts.example.com", pageHost: "example.com", secure: true,
                                           crossOrigin: true, fields: [
                                               LinkSignInField(kind: .username, label: "User"),
                                               LinkSignInField(kind: .email),
                                               LinkSignInField(kind: .password, label: "Password"),
                                               LinkSignInField(kind: .newPassword),
                                               LinkSignInField(kind: .oneTimeCode, label: "Code", length: 6),
                                           ])

    // MARK: Samples

    static var all: [LinkWireSample] { requests + hostRequests + responses + events + others }

    static var requests: [LinkWireSample] {
        typealias S = LinkWireSample
        return [
            S.request("enroll", .enroll(deviceKey: deviceKey, proof: Data([0xAA, 0xBB, 0xCC]), deviceName: "Ada's iPhone")),
            S.request("status", .status),
            S.request("subscribe", .subscribe),
            S.request("bots", .bots),
            S.request("createBot", .createBot(fullDraft)),
            S.request("createBot.minimal", .createBot(minimalDraft)),
            S.request("updateBot", .updateBot(id: id(0x01), fullDraft)),
            S.request("deleteBot", .deleteBot(id: id(0x01))),
            S.request("people", .people),
            S.request("shareBot", .shareBot(id: id(0x01), people: [id(0x50), id(0x51)])),
            S.request("setAvatar", .setAvatar(avatar)),
            S.request("setAvatar.minimal", .setAvatar(LinkAvatar())),
            S.request("setAvatar.none", .setAvatar(nil)),
            S.request("groups", .groups),
            S.request("createGroup", .createGroup(fullGroup.draft)),
            S.request("updateGroup", .updateGroup(id: id(0x60), minimalGroup.draft)),
            S.request("deleteGroup", .deleteGroup(id: id(0x60))),
            S.request("archive", .archive(LinkArchiveChange(id: id(0x01), archived: true))),
            S.request("suspend", .suspend(LinkSuspension(id: id(0x01), until: date(3600)))),
            S.request("suspend.lift", .suspend(LinkSuspension(id: id(0x01), until: nil))),
            S.request("stop", .stop(botID: id(0x01))),
            S.request("kick", .kick(botID: id(0x01))),
            S.request("confirmKick", .confirmKick(botID: id(0x01), confirmationID: id(0x09))),
            S.request("newSession", .newSession(botID: id(0x01))),
            S.request("organize", .organize(botID: id(0x01))),
            S.request("introduce", .introduce(conversationID: id(0x60))),
            S.request("messages", .messages(conversationID: id(0x11), after: 10)),
            S.request("messagePage", .messagePage(LinkMessagePage(conversationID: id(0x11), before: 100, limit: 20))),
            S.request("messagePage.after", .messagePage(LinkMessagePage(conversationID: id(0x11), after: 5))),
            S.request("messagePage.newest", .messagePage(LinkMessagePage(conversationID: id(0x11)))),
            S.request("searchMessages", .searchMessages(LinkMessageSearch(term: "hello", limit: 50))),
            S.request("send", .send(LinkOutgoingMessage(conversationID: id(0x11), id: id(0x83), body: "Hi",
                                                        attachmentIDs: [id(0x70)], taskID: id(0x40)))),
            S.request("send.minimal", .send(LinkOutgoingMessage(conversationID: id(0x11), id: id(0x84), body: "Plain"))),
            S.request("upload", .upload(conversationID: id(0x11), attachment: fullAttachment, offset: 0, data: Data([9, 8, 7]))),
            S.request("upload.minimal", .upload(conversationID: id(0x11), attachment: minimalAttachment, offset: 524_288, data: Data())),
            S.request("download", .download(conversationID: id(0x11), attachmentID: id(0x70), offset: 524_288)),
            S.request("react", .react(LinkReactionChange(conversationID: id(0x11), messageID: id(0x80), emoji: "👍", present: true))),
            S.request("markRead", .markRead(LinkReadMark(conversationID: id(0x11), messageID: id(0x80)))),
            S.request("pin", .pin(LinkPin(conversationID: id(0x11), pinned: false))),
            S.request("setNotifications", .setNotifications(LinkNotificationsChange(conversationID: id(0x60), notifications: .muted))),
            S.request("setNotifications.default", .setNotifications(LinkNotificationsChange(conversationID: id(0x60),
                                                                                             notifications: .default))),
            S.request("setGroupNotifications", .setGroupNotifications(.mentions)),
            S.request("pushTopic", .pushTopic(LinkPushTopic(topic: "topic-1"))),
            S.request("pushTopic.stop", .pushTopic(LinkPushTopic(topic: nil))),
            S.request("callPush", .callPush(LinkCallPush(grant: callGrant, callKey: Data(repeating: 0x07, count: 32)))),
            S.request("callPush.stop", .callPush(LinkCallPush(grant: nil, callKey: nil))),
            S.request("connections", .connections),
            S.request("saveConnection", .saveConnection(connectionDraft)),
            S.request("toolCatalog", .toolCatalog),
            S.request("deleteConnection", .deleteConnection(id: id(0x90))),
            S.request("assignConnections", .assignConnections(botID: id(0x01), connectionIDs: [id(0x90), id(0x91)])),
            S.request("signIn", .signIn(connectionID: id(0x90), redirect: URL(string: "noodle://sign-in")!)),
            S.request("finishSignIn", .finishSignIn(connectionID: id(0x90),
                                                    callback: URL(string: "noodle://sign-in?code=abc&state=x%2Fy")!)),
            S.request("computers", .computers),
            S.request("computerTemplates", .computerTemplates),
            S.request("createComputer", .createComputer(requestID: id(0xA9), LinkComputerDraft(
                template: "linux", name: "Box", description: "Linux box", symbol: "desktopcomputer", colour: 3))),
            S.request("updateComputer", .updateComputer(id: id(0xA0), LinkComputerDraft(name: "Renamed"))),
            S.request("assignComputers", .assignComputers(botID: id(0x01), computerIDs: [id(0xA0)])),
            S.request("deleteComputer", .deleteComputer(id: id(0xA0))),
            S.request("browsers", .browsers),
            S.request("createBrowser", .createBrowser(LinkBrowserDraft(name: "Work", description: "For work", symbol: "briefcase",
                                                                       colour: 5))),
            S.request("updateBrowser", .updateBrowser(id: id(0xB0), LinkBrowserDraft(name: "Renamed"))),
            S.request("deleteBrowser", .deleteBrowser(id: id(0xB0))),
            S.request("assignBrowsers", .assignBrowsers(botID: id(0x01), browserIDs: [])),
            S.request("openSurface", .openSurface(conversationID: id(0x11), attachmentID: id(0x70))),
            S.request("signInForm", .signInForm(conversationID: id(0x11), attachmentID: id(0x70))),
            S.request("fillSignIn", .fillSignIn(LinkSignInFill(conversationID: id(0x11), attachmentID: id(0x70), token: id(0xF0),
                                                               username: "ada", password: "secret", newPassword: "newer",
                                                               oneTimeCode: "123456", submit: true))),
            S.request("fillSignIn.minimal", .fillSignIn(LinkSignInFill(conversationID: id(0x11), attachmentID: id(0x70),
                                                                       token: id(0xF0)))),
            S.request("startCall", .startCall(LinkCallStart(conversationID: id(0x11)))),
            S.request("startCall.answering", .startCall(LinkCallStart(conversationID: id(0x11), answering: id(0xE9)))),
            S.request("linkPreview", .linkPreview(conversationID: id(0x11), attachmentID: id(0x70))),
            S.request("attachmentPreview", .attachmentPreview(conversationID: id(0x11), attachmentID: id(0x70), pixels: 256)),
            S.request("linkCard", .linkCard(conversationID: id(0x11), attachmentID: id(0x70))),
            S.request("picture.bot", .picture(.bot(id(0x01)))),
            S.request("picture.connection", .picture(.connection(id(0x90)))),
            S.request("picture.computer", .picture(.computer(id(0xA0)))),
            S.request("picture.browser", .picture(.browser(id(0xB0)))),
            S.request("picture.person", .picture(.person(id(0xC0)))),
            S.request("invite", .invite),
            S.request("users", .users),
            S.request("addUser", .addUser(LinkUserDraft(name: "Bea", plan: id(0xC9), canPairDevices: true, isSuspended: false))),
            S.request("addUser.minimal", .addUser(LinkUserDraft())),
            S.request("updateUser", .updateUser(id: id(0xC1), LinkUserDraft(isSuspended: true))),
            S.request("removeUser", .removeUser(id: id(0xC1))),
            S.request("removeDevice", .removeDevice(id: id(0xD1))),
            S.request("inviteUser", .inviteUser(id: id(0xC1))),
            S.request("leave", .leave),
            S.request("noodlet", .noodlet(conversationID: id(0x11), attachmentID: id(0x70))),
            S.request("noodletArchive", .noodletArchive(grant: id(0xAB), offset: 1_048_576)),
            S.request("noodletCall", .noodletCall(LinkNoodletCall(grant: id(0xAB), id: id(0xAC), offset: 0, total: 3,
                                                                  data: Data([1, 2, 3])))),
            S.request("setBackground", .setBackground(LinkBackgroundChoice(conversationID: id(0x11), preset: "sunset"))),
            S.request("setBackground.none", .setBackground(LinkBackgroundChoice(conversationID: id(0x11), preset: nil))),
            S.request("uploadBackground", .uploadBackground(LinkBackgroundPiece(conversationID: id(0x11), upload: id(0x31),
                                                                                filename: "photo.heic", byteCount: 6, offset: 3,
                                                                                data: Data([4, 5, 6])))),
            S.request("backgroundMedia", .backgroundMedia(LinkBackgroundFetch(conversationID: id(0x11), media: background.media!,
                                                                              compact: true, offset: 0))),
            S.request("hubSharing", .hubSharing(botID: id(0x01))),
            S.request("shareOnHub", .shareOnHub(botID: id(0x01), hub: "hub-one", people: [id(0x50)])),
            S.request("takeEffect", .takeEffect(conversationID: id(0x11))),
            S.request("declineCall", .declineCall(id: id(0xE9))),
        ]
    }

    static var hostRequests: [LinkWireSample] {
        typealias S = LinkWireSample
        return [
            S.host("publish", .publish(id: id(0x05), fullDraft)),
            S.host("bots", .bots),
            S.host("messagePage", .messagePage(LinkMessagePage(conversationID: id(0x15), before: 40, limit: 10))),
            S.host("download", .download(conversationID: id(0x15), attachmentID: id(0x75), offset: 0)),
            S.host("upload", .upload(conversationID: id(0x15), attachment: minimalAttachment, offset: 0, data: Data([1]))),
            S.host("reply", .reply(LinkHostedReply(conversationID: id(0x15), id: id(0x85), body: "Done.",
                                                   attachmentIDs: [id(0x71)],
                                                   links: [LinkAttachment(id: id(0x76), filename: "Example", mediaType: "text/html",
                                                                          byteCount: 0, url: URL(string: "https://example.com")!)]))),
            S.host("reply.minimal", .reply(LinkHostedReply(conversationID: id(0x15), id: id(0x86), body: ""))),
            S.host("delivered", .delivered(conversationID: id(0x15), messageIDs: [id(0x87), id(0x88)])),
            S.host("phase", .phase(botID: id(0x05), phase: .working)),
            S.host("react", .react(LinkReactionChange(conversationID: id(0x15), messageID: id(0x87), emoji: "❤️", present: false))),
            S.host("effect", .effect(conversationID: id(0x15), id: id(0x89), kind: "confetti")),
        ]
    }

    static var responses: [LinkWireSample] {
        typealias S = LinkWireSample
        return [
            S.response("status", .status(fullStatus)),
            S.response("status.minimal", .status(minimalStatus)),
            S.response("bots", .bots([fullBot, minimalBot, sharedBot])),
            S.response("bot", .bot(fullBot)),
            S.response("bot.minimal", .bot(minimalBot)),
            S.response("groups", .groups([fullGroup, minimalGroup])),
            S.response("group", .group(fullGroup)),
            S.response("messages", .messages(LinkMessages(messages: [fullMessage, minimalMessage, systemMessage], count: 3, start: 0))),
            S.response("messages.noStart", .messages(LinkMessages(messages: [], count: 0))),
            S.response("messageMatches", .messageMatches([LinkMessageMatch(conversationID: id(0x11), messageID: id(0x80),
                                                                           createdAt: date(), snippet: "…said hello…")])),
            S.response("message", .message(fullMessage)),
            S.response("connections", .connections([fullConnection, minimalConnection])),
            S.response("connection", .connection(fullConnection)),
            S.response("toolCatalog", .toolCatalog([
                LinkToolPreset(id: "linear", name: "Linear", summary: "Issues", instructions: "Use for tickets.",
                               endpoint: URL(string: "https://mcp.linear.app/sse")!, badge: "Experimental", icon: picture),
                LinkToolPreset(id: "bare", name: "Bare", summary: "", instructions: "", endpoint: URL(string: "https://example.com/mcp")!),
            ])),
            S.response("computers", .computers([fullComputer, minimalComputer])),
            S.response("computer", .computer(fullComputer)),
            S.response("computerTemplates", .computerTemplates([LinkComputerTemplate(id: "linux", name: "Linux",
                                                                                     description: "A Linux computer",
                                                                                     symbol: "terminal")])),
            S.response("browsers", .browsers([fullBrowser, minimalBrowser])),
            S.response("browser", .browser(fullBrowser)),
            S.response("chunk", .chunk(data: Data([1, 2, 3, 4]), total: 10)),
            S.response("chunk.packing", .chunk(data: Data(), total: 0)),
            S.response("picture", .picture(picture)),
            S.response("picture.none", .picture(nil)),
            S.response("linkCard", .linkCard(card)),
            S.response("linkCard.minimal", .linkCard(LinkCardInfo(title: "Tab"))),
            S.response("linkCard.none", .linkCard(nil)),
            S.response("invitation", .invitation(invitation)),
            S.response("users", .users(LinkUsers(users: [fullUser, minimalUser], plans: [LinkPlanChoice(id: id(0xC9), name: "Family")]))),
            S.response("user", .user(fullUser)),
            S.response("people", .people([LinkPerson(id: id(0x50), name: "Dee", avatar: avatar), LinkPerson(id: id(0x51), name: "Eve")])),
            S.response("kickConfirmation", .kickConfirmation(LinkKickConfirmation(id: id(0x09), title: "Kick Ada?",
                                                                                  message: "Recovery was interrupted.",
                                                                                  confirmTitle: "Kick", offersNewSession: true))),
            S.response("noodlet", .noodlet(LinkNoodlet(grant: id(0xAB), noodletID: id(0xAD), revision: "r1", byteCount: 4096,
                                                       manifest: Data(#"{"name":"Counter"}"#.utf8)))),
            S.response("noodletAnswer", .noodletAnswer(Data([0x7B, 0x7D]))),
            S.response("background", .background(background)),
            S.response("background.none", .background(LinkBackground())),
            S.response("hostedBots", .hostedBots([LinkHostedBot(id: id(0x05), conversations: [
                LinkGuestConversation(id: id(0x15), person: id(0x50), name: "Dee"),
            ]), LinkHostedBot(id: id(0x06), conversations: [])])),
            S.response("hostedBot", .hostedBot(LinkHostedBot(id: id(0x05), conversations: []))),
            S.response("hubSharing", .hubSharing([LinkHubSharing(id: "hub-one", name: "Home Hub",
                                                                 people: [LinkPerson(id: id(0x50), name: "Dee")],
                                                                 sharedWith: [id(0x50)])])),
            S.response("effect", .effect(LinkEffect(id: id(0x89), kind: "confetti"))),
            S.response("effect.none", .effect(nil)),
            S.response("signInForm", .signInForm(signInForm)),
            S.response("done", .done),
            S.response("failure", .failure("Something went wrong.")),
        ]
    }

    static var events: [LinkWireSample] {
        typealias S = LinkWireSample
        return [
            S.event("conversationChanged", .conversationChanged(conversationID: id(0x11), count: 42)),
            S.event("botsChanged", .botsChanged),
            S.event("groupsChanged", .groupsChanged),
            S.event("messageChanged", .messageChanged(fullMessage)),
            S.event("botPhase", .botPhase(botID: id(0x01), phase: .failed)),
            S.event("readChanged", .readChanged(conversationID: id(0x11), upTo: date(77))),
            S.event("pinChanged", .pinChanged(conversationID: id(0x11), pinnedAt: date(88))),
            S.event("pinChanged.unpinned", .pinChanged(conversationID: id(0x11), pinnedAt: nil)),
            S.event("notificationsChanged", .notificationsChanged(conversationID: id(0x60), notifications: .all)),
            S.event("groupNotificationsChanged", .groupNotificationsChanged(notifications: .mentions)),
            S.event("connectionsChanged", .connectionsChanged),
            S.event("signInPage", .signInPage(connectionID: id(0x90), url: URL(string: "https://auth.example.com/authorize?x=1")!)),
            S.event("computersChanged", .computersChanged),
            S.event("computerCreated", .computerCreated(requestID: id(0xA9), computer: fullComputer, error: nil)),
            S.event("computerCreated.failed", .computerCreated(requestID: id(0xA9), computer: nil, error: "No space left.")),
            S.event("browsersChanged", .browsersChanged),
            S.event("surfaceOpened", .surfaceOpened(sessionID: id(0x99))),
            S.event("surfaceFailed", .surfaceFailed(reason: "The noodlet stopped.")),
            S.event("surfaceControls", .surfaceControls(controls: gamepad)),
            S.event("surfaceControls.empty", .surfaceControls(controls: Gamepad())),
            S.event("backgroundChanged", .backgroundChanged(conversationID: id(0x11), background: background)),
            S.event("usersChanged", .usersChanged),
            S.event("effectWaiting", .effectWaiting(conversationID: id(0x11))),
            S.event("callRinging", .callRinging(LinkIncomingCall(id: id(0xE9), botID: id(0x01), conversationID: id(0x11),
                                                                 reason: "Your meeting starts soon", secondsLeft: 45))),
            S.event("callStopped", .callStopped(id: id(0xE9))),
        ]
    }

    static var others: [LinkWireSample] {
        typealias S = LinkWireSample
        return [
            S.callEvent("started", .started),
            S.callEvent("line", .line(LinkCallLine(speaker: .bot, text: "Hello", at: date()))),
            S.callEvent("line.noTime", .line(LinkCallLine(speaker: .you, text: "Hi", at: nil))),
            S.callEvent("ended", .ended(nil)),
            S.callEvent("ended.error", .ended("The bot hung up.")),
            S.caller("full", LinkCallPushCaller(botID: id(0x01), botName: "Ada", conversationID: id(0x11), expiresAt: 1_700_000_045)),
            S.caller("noExpiry", LinkCallPushCaller(botID: id(0x01), botName: "Ada", conversationID: id(0x11))),
            S.value("publicKey", hubKey),
            S.value("endpoint", LinkEndpoint(host: "100.64.0.1", port: 38_415)),
            S.invitationLink("standard", invitation),
        ]
    }
}
