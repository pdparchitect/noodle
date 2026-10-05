import CryptoKit
import Foundation
import ImageIO
@_exported import Surface

/// The version of the requests below. A Hub serves the versions it knows and names the app
/// to update for any other, rather than failing mid-conversation. Adding a request, an event
/// or a field keeps the version; changing what one means raises it. A field added later must
/// decode with a default when missing, and a request that may grow takes a struct, since an
/// enum case cannot. `LinkCompatibilityTests` holds version 1 as sent and must keep decoding.
public enum LinkProtocol {
    public static let version = 1
    /// Files travel in pieces this size, each one request, so no request nears the message limit.
    public static let chunkSize = 512 * 1024
    public static let supportedVersions: ClosedRange<Int> = 1...1
    /// How a Hub from before a request answers it, so a device can do without.
    public static let unknownRequest = "This Noodle Hub does not know that request. Update Noodle Hub."
    /// How a Hub answers for a noodlet it no longer has open, as after it restarted.
    public static let noodletForgotten = "Open this noodlet again."

    public static func encode(_ request: LinkRequest) throws -> Data {
        try encoder.encode(Envelope(version: version, fetchesPictures: true, request: request))
    }

    /// Whether the device fetches pictures with `picture` itself, so lists may leave them out.
    /// Devices from before it was added get them in lists, as they always did.
    public static func fetchesPictures(_ data: Data) -> Bool {
        (try? decoder.decode(Header.self, from: data))?.fetchesPictures ?? false
    }

    /// The request, or the failure to answer with when it cannot be served.
    public static func decode(_ data: Data) -> Result<LinkRequest, LinkError> {
        guard let header = try? decoder.decode(Header.self, from: data) else {
            return .failure(LinkError("The request could not be read."))
        }
        if header.version > supportedVersions.upperBound {
            return .failure(LinkError("This device needs a newer Noodle Hub. Update Noodle Hub."))
        }
        if header.version < supportedVersions.lowerBound {
            return .failure(LinkError("This Noodle Hub needs a newer Noodle. Update Noodle."))
        }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return .failure(LinkError(unknownRequest))
        }
        return .success(envelope.request)
    }

    public static func encode(_ response: LinkResponse) -> Data {
        (try? encoder.encode(response)) ?? Data()
    }

    public static func decodeResponse(_ data: Data) throws -> LinkResponse {
        do { return try decoder.decode(LinkResponse.self, from: data) }
        catch { throw LinkError("This Noodle Hub sent an answer this Noodle does not know. Update Noodle.") }
    }

    public static func encode(_ event: LinkEvent) -> Data {
        (try? encoder.encode(event)) ?? Data()
    }

    /// Events this Noodle does not know yet are skipped.
    public static func decodeEvent(_ data: Data) -> LinkEvent? {
        try? decoder.decode(LinkEvent.self, from: data)
    }

    private struct Header: Decodable {
        var version: Int
        var fetchesPictures: Bool?
    }
    private struct Envelope: Codable {
        var version: Int
        var fetchesPictures: Bool?
        var request: LinkRequest
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

public enum LinkRequest: Codable, Equatable, Sendable {
    /// Sent with the invitation's key, which works once: pairs `deviceKey` to the invitation's user.
    /// `proof` is `deviceKey`'s signature of the invitation's key, so nobody pairs a key they do not hold.
    case enroll(deviceKey: LinkPublicKey, proof: Data, deviceName: String)
    /// What the Hub lends this device's user.
    case status
    /// Keeps a stream open that the Hub pushes `LinkEvent`s down.
    case subscribe
    /// This user's bots on the Hub.
    case bots
    case createBot(LinkBotDraft)
    case updateBot(id: UUID, LinkBotDraft)
    case deleteBot(id: UUID)
    /// The other people on the Hub, to share a bot with. Answered with `people`.
    case people
    /// Shares one of this user's bots with exactly these other people on the Hub, each in a
    /// conversation of their own with it. Answers `bot`.
    case shareBot(id: UUID, people: [UUID])
    /// Changes this user's picture, as everyone on the Hub sees it, or nil for their initials. Answers `status`.
    case setAvatar(LinkAvatar?)
    /// This user's groups on the Hub: conversations with several of their bots.
    case groups
    /// Makes a group of this user's bots. Answers `group`.
    case createGroup(LinkGroupDraft)
    /// Renames a group or changes its bots. Answers `group`.
    case updateGroup(id: UUID, LinkGroupDraft)
    /// Deletes a group and its messages. Its bots stay.
    case deleteGroup(id: UUID)
    /// Archives or brings back one of this user's bots or groups. Answers `done`.
    case archive(LinkArchiveChange)
    /// Starts a failed bot again, as Kick does in Noodle. Answers `done`, or `kickConfirmation`
    /// when the failure needs the person to agree first.
    case kick(botID: UUID)
    /// Agrees to what a `kickConfirmation` asked, once, while the bot is still failing that way.
    case confirmKick(botID: UUID, confirmationID: UUID)
    /// Starts the bot with a fresh context, keeping its workspace, memory and messages.
    case newSession(botID: UUID)
    /// Messages of one of this user's conversations, from position `after` on.
    case messages(conversationID: UUID, after: Int)
    /// Part of a conversation, answered with `messages`: the newest first, earlier pages as the
    /// person scrolls back, or onward from where a device got to. Card pictures are left out;
    /// ask for each with `linkPreview` as its card comes into view.
    case messagePage(LinkMessagePage)
    /// Sends as this user. Attachments are uploaded first.
    case send(LinkOutgoingMessage)
    /// One piece of a file for a conversation, starting at `offset`. Pieces go in order.
    case upload(conversationID: UUID, attachment: LinkAttachment, offset: Int, data: Data)
    /// One piece of a conversation's file, starting at `offset`.
    case download(conversationID: UUID, attachmentID: UUID, offset: Int)
    /// Adds or removes this user's reaction to a message. Answers with the message.
    case react(LinkReactionChange)
    /// This user has read a conversation up to a message, on this device. The Hub keeps the
    /// furthest and pushes `readChanged` to the user's devices.
    case markRead(LinkReadMark)
    /// Where this device hears of unread replies while it is away from the Hub, or nil to stop.
    case pushTopic(LinkPushTopic)
    /// This user's tool connections on the Hub.
    case connections
    /// Adds a connection, or changes one of this user's. It reaches no bot until assigned.
    case saveConnection(LinkConnectionDraft)
    /// The services the Hub offers ready to connect, in the order to show them.
    case toolCatalog
    /// Deletes one of this user's connections and its sign-in.
    case deleteConnection(id: UUID)
    /// Replaces which of this user's connections one of their bots may use.
    case assignConnections(botID: UUID, connectionIDs: [UUID])
    /// Starts signing a connection in. The Hub pushes `signInPage` to this device; `redirect`
    /// is where this device's browser returns.
    case signIn(connectionID: UUID, redirect: URL)
    /// The address the browser returned to, which carries the sign-in's answer.
    case finishSignIn(connectionID: UUID, callback: URL)
    /// This user's computers on the Hub.
    case computers
    /// The kinds of computer the Hub can make.
    case computerTemplates
    /// Starts making a computer for this user. Making one can take many minutes, so the Hub
    /// answers at once and pushes `computerCreated` with the same `requestID` when it is done.
    case createComputer(requestID: UUID, LinkComputerDraft)
    /// Changes one of this user's computers. Answers with it.
    case updateComputer(id: UUID, LinkComputerDraft)
    /// Replaces which of this user's computers one of their bots may use.
    case assignComputers(botID: UUID, computerIDs: [UUID])
    /// Moves one of this user's computers to the Trash on the Hub's Mac.
    case deleteComputer(id: UUID)
    /// This user's browsers on the Hub.
    case browsers
    /// Makes a browser for this user. Answers with it; it reaches no bot until assigned.
    case createBrowser(LinkBrowserDraft)
    /// Changes one of this user's browsers. Answers with it.
    case updateBrowser(id: UUID, LinkBrowserDraft)
    /// Deletes one of this user's browsers, with its sign-ins and history.
    case deleteBrowser(id: UUID)
    /// Replaces which of this user's browsers one of their bots may use.
    case assignBrowsers(botID: UUID, browserIDs: [UUID])
    /// Opens a channel showing what a link in one of this user's conversations points at, live.
    /// See `LinkSurface` for what travels on it.
    case openSurface(conversationID: UUID, attachmentID: UUID)
    /// Opens a channel for a voice call with the bot of one of this user's conversations. See
    /// `LinkCallEvent` for what comes down it; closing it hangs up.
    case startCall(LinkCallStart)
    /// The latest picture of what a link a bot shared points at, for its card, when the link
    /// itself carries none, as a noodlet's does not. Answered with `picture`.
    case linkPreview(conversationID: UUID, attachmentID: UUID)
    /// A live attachment’s title and preview, without opening it.
    case linkCard(conversationID: UUID, attachmentID: UUID)
    /// A picture a list left out, answered with `picture`.
    case picture(LinkPictureOwner)
    /// A one-time invitation for another device of this user, when the Hub lets them pair
    /// their own devices. Answered with `invitation`.
    case invite
    /// For admins: the Hub's users with their devices, and the plans to put them on. Answered with `users`.
    case users
    /// For admins: adds a user who is not an admin. Answered with `user`.
    case addUser(LinkUserDraft)
    /// For admins: renames, moves or stops pairing a user who is not an admin. Answered with `user`.
    case updateUser(id: UUID, LinkUserDraft)
    /// For admins: removes a user who is not an admin, with their devices and everything they keep on the Hub.
    case removeUser(id: UUID)
    /// For admins: unpairs a device of a user who is not an admin.
    case removeDevice(id: UUID)
    /// For admins: a one-time invitation for a device of a user who is not an admin. Answered with `invitation`.
    case inviteUser(id: UUID)
    /// Unpairs this device from the Hub. Answered with `done`.
    case leave
    /// Readies a noodlet a bot shared in one of this user's conversations to run on this device.
    /// Answered with `noodlet`.
    case noodlet(conversationID: UUID, attachmentID: UUID)
    /// A piece of the noodlet a `noodlet` answer readied, starting at `offset`. Answered with `chunk`.
    case noodletArchive(grant: UUID, offset: Int)
    /// A piece of one call a noodlet running on this device makes on its data and secrets, which
    /// stay on the Hub. Answered with `done` until the last piece, then with `noodletAnswer`.
    case noodletCall(LinkNoodletCall)
    /// Sets a conversation's background to a gradient, or to none. Answers `background`.
    case setBackground(LinkBackgroundChoice)
    /// One piece of a picture or video for a conversation's background, starting at `offset`. Pieces
    /// go in order; the last one sets it and answers `background`, the others `done`.
    case uploadBackground(LinkBackgroundPiece)
    /// One piece of a conversation's background file. Answered with `chunk`.
    case backgroundMedia(LinkBackgroundFetch)
}

/// A conversation's background, kept on the Hub so every device shows the same one.
public struct LinkBackground: Codable, Equatable, Sendable {
    /// One of Noodle's gradients, by name.
    public var preset: String?
    /// The picture or video, by a name that changes whenever it does, so a device fetches each once.
    public var media: String?
    /// `image`, `video` or `dynamicImage`, as Noodle names them.
    public var mediaKind: String?

    public init(preset: String? = nil, media: String? = nil, mediaKind: String? = nil) {
        self.preset = preset
        self.media = media
        self.mediaKind = mediaKind
    }

    /// `media` when it is a name a Hub gives, a UUID with a known extension, so a device can keep
    /// the file under it: never a path, nor anything else a Hub could send.
    public var mediaFilename: String? {
        guard let media else { return nil }
        let parts = media.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              ["jpg", "heic", "heif", "mov", "mp4", "m4v"].contains(parts[1]) else { return nil }
        return media
    }

    /// The name a device keeps the small copy under: a video plays as MP4, anything else is a JPEG.
    public var compactFilename: String? {
        mediaFilename.map { "\($0.prefix { $0 != "." }).\(mediaKind == "video" ? "mp4" : "jpg")" }
    }
}

/// A gradient for a conversation's background, or nil for none.
public struct LinkBackgroundChoice: Codable, Equatable, Sendable {
    public var conversationID: UUID
    public var preset: String?

    public init(conversationID: UUID, preset: String?) {
        self.conversationID = conversationID
        self.preset = preset
    }
}

/// A piece of a picture or video for a conversation's background. Every piece of one file has its `upload`.
public struct LinkBackgroundPiece: Codable, Equatable, Sendable {
    public var conversationID: UUID
    public var upload: UUID
    /// Its extension says what it is.
    public var filename: String
    public var byteCount: Int
    public var offset: Int
    public var data: Data

    public init(conversationID: UUID, upload: UUID, filename: String, byteCount: Int, offset: Int, data: Data) {
        self.conversationID = conversationID
        self.upload = upload
        self.filename = filename
        self.byteCount = byteCount
        self.offset = offset
        self.data = data
    }
}

/// A piece of a conversation's background file, as the Hub keeps it, or `compact`: a small copy for a phone.
public struct LinkBackgroundFetch: Codable, Equatable, Sendable {
    public var conversationID: UUID
    public var media: String
    public var compact: Bool
    public var offset: Int

    public init(conversationID: UUID, media: String, compact: Bool, offset: Int) {
        self.conversationID = conversationID
        self.media = media
        self.compact = compact
        self.offset = offset
    }
}

/// A noodlet readied to run on a device.
public struct LinkNoodlet: Codable, Equatable, Sendable {
    /// Names this opening in `noodletArchive` and `noodletCall`, for this user only, for a while.
    public var grant: UUID
    /// The noodlet, the same whichever conversation shared it: its files are cached under it.
    public var noodletID: UUID
    /// Changes whenever its files do.
    public var revision: String
    /// The size of its archive.
    public var byteCount: Int
    /// Its noodlet.json, which says how it wants to run before its files are fetched.
    public var manifest: Data

    public init(grant: UUID, noodletID: UUID, revision: String, byteCount: Int, manifest: Data) {
        self.grant = grant
        self.noodletID = noodletID
        self.revision = revision
        self.byteCount = byteCount
        self.manifest = manifest
    }
}

/// A piece of a call a noodlet's page makes on its data and secrets. A call that does not fit one
/// request goes in pieces of the same `id`, in order.
public struct LinkNoodletCall: Codable, Equatable, Sendable {
    public var grant: UUID
    public var id: UUID
    public var offset: Int
    public var total: Int
    /// This piece of the call, as its app encodes it.
    public var data: Data

    public init(grant: UUID, id: UUID, offset: Int, total: Int, data: Data) {
        self.grant = grant
        self.id = id
        self.offset = offset
        self.total = total
        self.data = data
    }
}

/// Whose picture: a bot's or a person's, or the icon of a connection, computer or browser.
public enum LinkPictureOwner: Codable, Hashable, Sendable {
    case bot(UUID), connection(UUID), computer(UUID), browser(UUID), person(UUID)
}

/// Pictures travel apart from the lists that show them: a list carries each one's digest, and
/// a device fetches only those it does not keep yet.
public enum LinkPicture {
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// Something a list shows with a picture that may travel apart from it.
public protocol LinkPictured: Sendable {
    static var pictureFolder: String { get }
    var pictureOwner: LinkPictureOwner { get }
    var picture: Data? { get set }
    var pictureDigest: String? { get set }
}

extension LinkPictured {
    /// As a list sends it to a device that fetches pictures itself.
    public var withoutPicture: Self {
        guard let picture else { return self }
        var copy = self
        copy.pictureDigest = LinkPicture.digest(picture)
        copy.picture = nil
        return copy
    }
}

extension LinkBot: LinkPictured {
    public static let pictureFolder = "Bots"
    public var pictureOwner: LinkPictureOwner { .bot(id) }
    public var picture: Data? {
        get { draft.avatarImageData }
        set { draft.avatarImageData = newValue }
    }
    public var pictureDigest: String? {
        get { draft.avatarImageDigest }
        set { draft.avatarImageDigest = newValue }
    }
}

extension LinkPerson: LinkPictured {
    public static let pictureFolder = "People"
    public var pictureOwner: LinkPictureOwner { .person(id) }
    public var picture: Data? {
        get { avatar?.image }
        set { avatar?.image = newValue }
    }
    public var pictureDigest: String? {
        get { avatar?.imageDigest }
        set { avatar?.imageDigest = newValue }
    }
}

extension LinkUser: LinkPictured {
    public static let pictureFolder = "Users"
    public var pictureOwner: LinkPictureOwner { .person(id) }
    public var picture: Data? {
        get { avatar?.image }
        set { avatar?.image = newValue }
    }
    public var pictureDigest: String? {
        get { avatar?.imageDigest }
        set { avatar?.imageDigest = newValue }
    }
}

extension LinkConnection: LinkPictured {
    public static let pictureFolder = "Connections"
    public var pictureOwner: LinkPictureOwner { .connection(id) }
    public var picture: Data? {
        get { iconData }
        set { iconData = newValue }
    }
    public var pictureDigest: String? {
        get { iconDigest }
        set { iconDigest = newValue }
    }
}

extension LinkComputer: LinkPictured {
    public static let pictureFolder = "Computers"
    public var pictureOwner: LinkPictureOwner { .computer(id) }
    public var picture: Data? {
        get { icon }
        set { icon = newValue }
    }
    public var pictureDigest: String? {
        get { iconDigest }
        set { iconDigest = newValue }
    }
}

extension LinkBrowser: LinkPictured {
    public static let pictureFolder = "Browsers"
    public var pictureOwner: LinkPictureOwner { .browser(id) }
    public var picture: Data? {
        get { icon }
        set { icon = newValue }
    }
    public var pictureDigest: String? {
        get { iconDigest }
        set { iconDigest = newValue }
    }
}

public enum LinkResponse: Codable, Equatable, Sendable {
    case status(LinkStatus)
    case bots([LinkBot])
    case bot(LinkBot)
    case groups([LinkGroup])
    case group(LinkGroup)
    case messages(LinkMessages)
    case message(LinkMessage)
    case connections([LinkConnection])
    case connection(LinkConnection)
    case toolCatalog([LinkToolPreset])
    case computers([LinkComputer])
    case computer(LinkComputer)
    case computerTemplates([LinkComputerTemplate])
    case browsers([LinkBrowser])
    case browser(LinkBrowser)
    /// A piece of a file, and the file's full size.
    case chunk(data: Data, total: Int)
    /// A picture, or none when there is nothing to show yet.
    case picture(Data?)
    case linkCard(LinkCardInfo?)
    case invitation(LinkInvitation)
    case users(LinkUsers)
    case user(LinkUser)
    case people([LinkPerson])
    case kickConfirmation(LinkKickConfirmation)
    case noodlet(LinkNoodlet)
    /// What a noodlet's call answered, as its app encodes it.
    case noodletAnswer(Data)
    case background(LinkBackground)
    case done
    case failure(String)
}

/// Pushed down a subscription. Devices fetch what changed with ordinary requests.
public enum LinkEvent: Codable, Equatable, Sendable {
    case conversationChanged(conversationID: UUID, count: Int)
    case botsChanged
    /// This user's groups changed: made, renamed, deleted, or their bots changed.
    case groupsChanged
    /// A message already sent changed, as when someone reacted to it.
    case messageChanged(LinkMessage)
    /// What a bot is doing now.
    case botPhase(botID: UUID, phase: LinkBotPhase)
    /// This user read a conversation further, on one of their devices: every message sent up to `upTo`.
    case readChanged(conversationID: UUID, upTo: Date)
    /// This user's connections, their sign-in or their bots changed.
    case connectionsChanged
    /// Open this page in the browser to sign a connection in, then send `finishSignIn`.
    case signInPage(connectionID: UUID, url: URL)
    /// This user's computers or their bots changed.
    case computersChanged
    /// A computer asked for with `createComputer` was made, or why it was not.
    case computerCreated(requestID: UUID, computer: LinkComputer?, error: String?)
    /// This user's browsers or their bots changed.
    case browsersChanged
    /// A surface channel is ready; video follows as `LinkSurface` packets.
    case surfaceOpened(sessionID: UUID)
    /// What a surface channel was opened for could not be shown, and why; the channel ends.
    case surfaceFailed(reason: String)
    /// The keys a game on a surface channel declared, sent before its video, for a viewer
    /// without a keyboard to show as a controller.
    case surfaceControls(controls: Gamepad)
    /// A conversation's background changed, on any device or on the Hub.
    case backgroundChanged(conversationID: UUID, background: LinkBackground)
    /// Pushed to admins: the Hub's users, their devices or its plans changed.
    case usersChanged
}

/// Someone else on the Hub, as anyone sharing a bot sees them.
public struct LinkPerson: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Nil until they choose one: they show their initials. Its image travels apart, as `picture`.
    public var avatar: LinkAvatar?

    public init(id: UUID, name: String, avatar: LinkAvatar? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
    }

    /// Who can talk to a bot shared with `people`, named, as Sharing says it.
    public static func sharingSummary(bot: String, people: [String]) -> String {
        let trimmed = bot.trimmingCharacters(in: .whitespacesAndNewlines)
        let bot = trimmed.isEmpty ? "this bot" : trimmed
        guard !people.isEmpty else { return "Only you can talk to \(bot)." }
        return "\(people.formatted(.list(type: .and))) can talk to \(bot) too."
    }
}

/// How a person shows on the Hub: a photo, or a symbol or their initials on a colour.
public struct LinkAvatar: Codable, Hashable, Sendable {
    /// Nil shows their initials.
    public var symbol: String?
    /// An index into the same colours as bots'.
    public var colour: Int
    public var image: Data?
    /// The image's digest. Sent without `image`, it keeps the one the Hub has.
    public var imageDigest: String?

    public init(symbol: String? = nil, colour: Int = 0, image: Data? = nil, imageDigest: String? = nil) {
        self.symbol = symbol
        self.colour = colour
        self.image = image
        self.imageDigest = imageDigest
    }

    private enum CodingKeys: String, CodingKey { case symbol, colour, image, imageDigest }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        colour = try c.decode(.colour, or: 0)
        image = try c.decodeIfPresent(Data.self, forKey: .image)
        imageDigest = try c.decodeIfPresent(String.self, forKey: .imageDigest)
    }

    /// What someone shows until they choose: their initials, on a colour of their own.
    public static func standard(for id: UUID?) -> LinkAvatar { LinkAvatar(colour: Int(id?.uuid.0 ?? 0)) }

    /// The first letters of the first two words of their name.
    public static func initials(of name: String) -> String {
        String(name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)).uppercased()
    }

    /// Whether it shows a photo, fetched yet or not.
    public var hasImage: Bool { image != nil || imageDigest != nil }

    public mutating func removeImage() {
        image = nil
        imageDigest = nil
    }

    /// As a change sends it: without the image when it is the one the Hub has.
    public var leavingOutKnownImage: LinkAvatar {
        var avatar = self
        if let image {
            if imageDigest == LinkPicture.digest(image) { avatar.image = nil } else { avatar.imageDigest = nil }
        }
        return avatar
    }
}

/// The Hub's users as its admins see them, and the plans they can be put on.
public struct LinkUsers: Codable, Equatable, Sendable {
    public var users: [LinkUser]
    public var plans: [LinkPlanChoice]

    public init(users: [LinkUser], plans: [LinkPlanChoice]) {
        self.users = users
        self.plans = plans
    }
}

public struct LinkUser: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var plan: UUID
    public var canPairDevices: Bool
    /// Admins are managed only on the Hub itself, so a device shows them without changing them.
    public var isAdmin: Bool
    public var devices: [LinkUserDevice]
    /// Nil until they choose one: they show their initials. Its image travels apart, as `picture`.
    public var avatar: LinkAvatar?

    public init(id: UUID, name: String, plan: UUID, canPairDevices: Bool, isAdmin: Bool, devices: [LinkUserDevice],
                avatar: LinkAvatar? = nil) {
        self.id = id
        self.name = name
        self.plan = plan
        self.canPairDevices = canPairDevices
        self.isAdmin = isAdmin
        self.devices = devices
        self.avatar = avatar
    }
}

public struct LinkUserDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var paired: Date
    public var lastSeen: Date?
    public var isConnected: Bool

    public init(id: UUID, name: String, paired: Date, lastSeen: Date?, isConnected: Bool) {
        self.id = id
        self.name = name
        self.paired = paired
        self.lastSeen = lastSeen
        self.isConnected = isConnected
    }
}

/// A plan a user can be put on. What it lends is set on the Hub.
public struct LinkPlanChoice: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// What an admin sets on a user they add or change. Nil fields stay as they are, or take the
/// Hub's defaults for a new user. There is no admin field: only the Hub itself makes admins.
public struct LinkUserDraft: Codable, Equatable, Sendable {
    public var name: String?
    public var plan: UUID?
    public var canPairDevices: Bool?

    public init(name: String? = nil, plan: UUID? = nil, canPairDevices: Bool? = nil) {
        self.name = name
        self.plan = plan
        self.canPairDevices = canPairDevices
    }
}

/// What a device sets on a browser it makes or edits on the Hub. Nil fields stay as they are.
public struct LinkBrowserDraft: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var symbol: String?
    public var colour: Int?

    public init(name: String, description: String? = nil, symbol: String? = nil, colour: Int? = nil) {
        self.name = name
        self.description = description
        self.symbol = symbol
        self.colour = colour
    }
}

/// A browser one user keeps on the Hub.
public struct LinkBrowser: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String?
    public var symbol: String
    public var colour: Int
    public var icon: Data?
    /// The icon's digest, sent in its place when a list leaves it out.
    public var iconDigest: String?
    /// Bots may not use it while its owner has paused them.
    public var paused: Bool
    /// The bots it is assigned to.
    public var botIDs: [UUID]

    public init(id: UUID, name: String, description: String? = nil, symbol: String = "globe", colour: Int = 0,
                icon: Data? = nil, paused: Bool = false, botIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.symbol = symbol
        self.colour = colour
        self.icon = icon
        self.paused = paused
        self.botIDs = botIDs
    }
}

/// What a device sets on a computer it makes or edits on the Hub. Nil fields stay as they are.
public struct LinkComputerDraft: Codable, Equatable, Sendable {
    /// The template a new computer is made from; ignored when editing.
    public var template: String?
    public var name: String
    public var description: String?
    public var symbol: String?
    public var colour: Int?

    public init(template: String? = nil, name: String, description: String? = nil, symbol: String? = nil, colour: Int? = nil) {
        self.template = template
        self.name = name
        self.description = description
        self.symbol = symbol
        self.colour = colour
    }
}

/// A computer one user keeps on the Hub.
public struct LinkComputer: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String?
    public var kind: String
    public var state: String
    public var symbol: String
    public var colour: Int
    public var icon: Data?
    /// The icon's digest, sent in its place when a list leaves it out.
    public var iconDigest: String?
    /// The bots it is assigned to.
    public var botIDs: [UUID]

    public init(id: UUID, name: String, description: String? = nil, kind: String, state: String, symbol: String,
                colour: Int = 0, icon: Data? = nil, botIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.state = state
        self.symbol = symbol
        self.colour = colour
        self.icon = icon
        self.botIDs = botIDs
    }
}

/// A kind of computer the Hub can make.
public struct LinkComputerTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var symbol: String

    public init(id: String, name: String, description: String, symbol: String) {
        self.id = id
        self.name = name
        self.description = description
        self.symbol = symbol
    }
}

/// What a device sets on a tool connection it keeps on the Hub.
public struct LinkConnectionDraft: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var endpoint: URL
    public var description: String
    public var instructions: String

    public init(id: UUID = UUID(), name: String, endpoint: URL, description: String = "", instructions: String = "") {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.description = description
        self.instructions = instructions
    }
}

/// A service the Hub offers ready to connect. Saving it takes `name` and `endpoint`, with
/// `summary` as the description and `instructions` as they are.
public struct LinkToolPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var instructions: String
    public var endpoint: URL
    /// Shown beside the name, as "Experimental".
    public var badge: String?
    public var icon: Data?

    public init(id: String, name: String, summary: String, instructions: String, endpoint: URL, badge: String? = nil, icon: Data? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.endpoint = endpoint
        self.badge = badge
        self.icon = icon
    }
}

/// A tool connection one user keeps on the Hub.
public struct LinkConnection: Codable, Equatable, Identifiable, Sendable {
    public var draft: LinkConnectionDraft
    public var iconData: Data?
    /// The icon's digest, sent in its place when a list leaves it out.
    public var iconDigest: String?
    /// The bots it is assigned to.
    public var botIDs: [UUID]
    public var signedIn: Bool
    /// Why it last failed, safe to show.
    public var problem: String?
    public var id: UUID { draft.id }

    public init(draft: LinkConnectionDraft, iconData: Data? = nil, botIDs: [UUID] = [], signedIn: Bool = false, problem: String? = nil) {
        self.draft = draft
        self.iconData = iconData
        self.botIDs = botIDs
        self.signedIn = signedIn
        self.problem = problem
    }
}

public struct LinkStatus: Codable, Equatable, Sendable {
    public var hubName: String
    public var userName: String
    public var planName: String
    public var harnesses: [LinkHarness]
    /// The Hub's current addresses, so a device keeps up when they change.
    public var endpoints: [LinkEndpoint]
    /// The newest request version this Hub serves.
    public var protocolVersion: Int
    /// Whether the user may ask for an invitation for another of their devices with `invite`.
    public var canPairDevices: Bool
    /// Whether the user may manage the Hub's other users with `users` and the requests after it.
    public var isAdmin: Bool
    /// Whether the user may share their bots with other people on the Hub with `shareBot`.
    public var canShareBots: Bool
    /// Who the user is, to fetch their own picture with `picture`. Nil from a Hub without pictures of people.
    public var userID: UUID?
    /// The user's picture, its image left out. Nil while they show their initials.
    public var avatar: LinkAvatar?

    public init(hubName: String, userName: String, planName: String, harnesses: [LinkHarness], endpoints: [LinkEndpoint],
                protocolVersion: Int = LinkProtocol.version, canPairDevices: Bool = false, isAdmin: Bool = false,
                canShareBots: Bool = false, userID: UUID? = nil, avatar: LinkAvatar? = nil) {
        self.hubName = hubName
        self.userName = userName
        self.planName = planName
        self.harnesses = harnesses
        self.endpoints = endpoints
        self.protocolVersion = protocolVersion
        self.canPairDevices = canPairDevices
        self.isAdmin = isAdmin
        self.canShareBots = canShareBots
        self.userID = userID
        self.avatar = avatar
    }

    private enum CodingKeys: String, CodingKey {
        case hubName, userName, planName, harnesses, endpoints, protocolVersion, canPairDevices, isAdmin, canShareBots, userID, avatar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hubName = try c.decode(String.self, forKey: .hubName)
        userName = try c.decode(.userName, or: "")
        planName = try c.decode(.planName, or: "")
        harnesses = try c.decode(.harnesses, or: [])
        endpoints = try c.decode(.endpoints, or: [])
        protocolVersion = try c.decode(.protocolVersion, or: 1)
        canPairDevices = try c.decode(.canPairDevices, or: false)
        isAdmin = try c.decode(.isAdmin, or: false)
        canShareBots = try c.decode(.canShareBots, or: false)
        userID = try c.decodeIfPresent(UUID.self, forKey: .userID)
        avatar = try c.decodeIfPresent(LinkAvatar.self, forKey: .avatar)
    }
}

/// A harness login the Hub lends. `profile` and `profileName` are nil for the harness's own login.
public struct LinkHarness: Codable, Hashable, Sendable {
    public var provider: String
    public var providerName: String
    public var profile: UUID?
    public var profileName: String?
    /// The models a bot on it may use, as far as the Hub knows them; empty from a Hub that does not say.
    public var models: [LinkModel]
    /// Only `models` may be used, so a bot cannot be left on the harness default.
    public var restrictsModels: Bool
    /// The voices a bot on it can speak with on calls; empty when it takes no calls.
    public var voices: [LinkCallVoice]

    public init(provider: String, providerName: String, profile: UUID? = nil, profileName: String?,
                models: [LinkModel] = [], restrictsModels: Bool = false, voices: [LinkCallVoice] = []) {
        self.provider = provider
        self.providerName = providerName
        self.profile = profile
        self.profileName = profileName
        self.models = models
        self.restrictsModels = restrictsModels
        self.voices = voices
    }

    private enum CodingKeys: String, CodingKey { case provider, providerName, profile, profileName, models, restrictsModels, voices }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        providerName = try c.decode(.providerName, or: provider)
        profile = try c.decodeIfPresent(UUID.self, forKey: .profile)
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
        models = try c.decode(.models, or: [])
        restrictsModels = try c.decode(.restrictsModels, or: false)
        voices = try c.decode(.voices, or: [])
    }

    /// What a new bot starts on: the first model when the plan leaves no harness default.
    public var initialModel: String? { restrictsModels ? models.first?.id : nil }
}

/// A model a lent harness offers.
public struct LinkModel: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The reasoning efforts a bot on it may choose; empty when it has none, or from a Hub that does not say.
    public var efforts: [LinkEffort]
    /// The effort the model uses when the bot leaves it on Default.
    public var defaultEffort: String?

    public init(id: String, name: String, efforts: [LinkEffort] = [], defaultEffort: String? = nil) {
        self.id = id
        self.name = name
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }

    private enum CodingKeys: String, CodingKey { case id, name, efforts, defaultEffort }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        efforts = try c.decode(.efforts, or: [])
        defaultEffort = try c.decodeIfPresent(String.self, forKey: .defaultEffort)
    }
}

/// A reasoning effort a model offers.
public struct LinkEffort: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What a device sets on a bot it keeps on the Hub.
public struct LinkBotDraft: Codable, Equatable, Sendable {
    public var name: String
    public var provider: String
    public var profile: UUID?
    public var model: String?
    public var reasoningEffort: String?
    public var publicDescription: String
    public var backstory: String
    public var avatarSymbolName: String?
    public var avatarColorIndex: Int
    public var avatarImageData: Data?
    /// The picture the Hub has. Sent without `avatarImageData`, it keeps that picture.
    public var avatarImageDigest: String?
    /// The voice it speaks with on calls. Nil leaves it to the Hub, which picks one for its name.
    public var voice: String?

    public init(name: String, provider: String, profile: UUID? = nil, model: String? = nil, reasoningEffort: String? = nil,
                publicDescription: String = "", backstory: String = "", avatarSymbolName: String? = nil,
                avatarColorIndex: Int = 0, avatarImageData: Data? = nil) {
        self.name = name
        self.provider = provider
        self.profile = profile
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.publicDescription = publicDescription
        self.backstory = backstory
        self.avatarSymbolName = avatarSymbolName
        self.avatarColorIndex = avatarColorIndex
        self.avatarImageData = avatarImageData
    }

    private enum CodingKeys: String, CodingKey {
        case name, provider, profile, model, reasoningEffort, publicDescription, backstory, avatarSymbolName, avatarColorIndex, avatarImageData,
             avatarImageDigest, voice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(String.self, forKey: .provider)
        profile = try c.decodeIfPresent(UUID.self, forKey: .profile)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        publicDescription = try c.decode(.publicDescription, or: "")
        backstory = try c.decode(.backstory, or: "")
        avatarSymbolName = try c.decodeIfPresent(String.self, forKey: .avatarSymbolName)
        avatarColorIndex = try c.decode(.avatarColorIndex, or: 0)
        avatarImageData = try c.decodeIfPresent(Data.self, forKey: .avatarImageData)
        avatarImageDigest = try c.decodeIfPresent(String.self, forKey: .avatarImageDigest)
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
    }

    /// Puts the bot on `model` of `harness`. Its effort stays while that model offers it; otherwise it
    /// becomes the model's default, or Default when the model offers none, as in the Mac's bot editor.
    public mutating func setModel(_ model: String?, on harness: LinkHarness?) {
        self.model = model
        guard let reasoningEffort else { return }
        let chosen = harness?.models.first { $0.id == model }
        if chosen?.efforts.contains(where: { $0.id == reasoningEffort }) != true {
            self.reasoningEffort = chosen?.defaultEffort
        }
    }

    /// Whether the bot shows a picture, fetched yet or not.
    public var hasPicture: Bool { avatarImageData != nil || avatarImageDigest != nil }

    public mutating func removePicture() {
        avatarImageData = nil
        avatarImageDigest = nil
    }

    /// As an edit sends it: without the picture when it is the one the Hub has.
    public var leavingOutKnownPicture: LinkBotDraft {
        var draft = self
        if let data = avatarImageData {
            if avatarImageDigest == LinkPicture.digest(data) { draft.avatarImageData = nil } else { draft.avatarImageDigest = nil }
        }
        return draft
    }
}

/// A bot on the Hub and its conversation with whoever it is listed for: its owner, or someone it is shared with.
public struct LinkBot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var conversationID: UUID
    public var draft: LinkBotDraft
    public var createdAt: Date
    /// What it was doing when listed. Nil from a Hub that does not say, or in a way this app does not know.
    public var phase: LinkBotPhase?
    /// When the latest message its owner has read was sent. Nil when they have read none, or from
    /// a Hub that does not keep it.
    public var readUpTo: Date?
    /// The one line the bot set itself, such as what it is busy with. Not part of the draft: devices never set it.
    public var status: String?
    /// When it was archived: it keeps everything but does not run or take messages. Set with `archive`.
    public var archivedAt: Date?
    /// Its conversation's background. Nil from a Hub that does not keep backgrounds.
    public var background: LinkBackground?
    /// For its owner: the people it is shared with.
    public var sharedWith: [UUID]
    /// For someone it is shared with: whose it is. They talk with it and nothing else, so its
    /// draft carries only its name, description and picture, and it comes without its status.
    public var owner: String?
    /// Whether this person can call it: its harness speaks. False from a Hub without calls.
    public var canCall: Bool

    public init(id: UUID, conversationID: UUID, draft: LinkBotDraft, createdAt: Date, phase: LinkBotPhase? = nil,
                readUpTo: Date? = nil, status: String? = nil, archivedAt: Date? = nil, background: LinkBackground? = nil,
                sharedWith: [UUID] = [], owner: String? = nil, canCall: Bool = false) {
        self.id = id
        self.conversationID = conversationID
        self.draft = draft
        self.createdAt = createdAt
        self.phase = phase
        self.readUpTo = readUpTo
        self.status = status
        self.archivedAt = archivedAt
        self.background = background
        self.sharedWith = sharedWith
        self.owner = owner
        self.canCall = canCall
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationID, draft, createdAt, phase, readUpTo, status, archivedAt, background, sharedWith, owner, canCall
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        draft = try c.decode(LinkBotDraft.self, forKey: .draft)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        phase = try c.decodeIfPresent(String.self, forKey: .phase).flatMap(LinkBotPhase.init(rawValue:))
        readUpTo = try c.decodeIfPresent(Date.self, forKey: .readUpTo)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        background = try c.decodeIfPresent(LinkBackground.self, forKey: .background)
        sharedWith = try c.decodeIfPresent([UUID].self, forKey: .sharedWith) ?? []
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        canCall = try c.decode(.canCall, or: false)
    }
}

/// What a device sets on a group it makes or edits on the Hub.
public struct LinkGroupDraft: Codable, Equatable, Sendable {
    public var name: String
    public var publicDescription: String
    /// Bots of the same user, at least one.
    public var botIDs: [UUID]

    public init(name: String, publicDescription: String = "", botIDs: [UUID]) {
        self.name = name
        self.publicDescription = publicDescription
        self.botIDs = botIDs
    }
}

/// A conversation between a user and several of their bots on the Hub. Its ID is the
/// conversation's, which messages name as for a bot's own conversation.
public struct LinkGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var draft: LinkGroupDraft
    public var createdAt: Date
    /// When the latest message its user has read was sent. Nil when they have read none.
    public var readUpTo: Date?
    /// When it was archived: it keeps its messages but takes no new ones. Its bots keep running.
    public var archivedAt: Date?
    /// Its background. Nil from a Hub that does not keep backgrounds.
    public var background: LinkBackground?

    public init(id: UUID, draft: LinkGroupDraft, createdAt: Date, readUpTo: Date? = nil, archivedAt: Date? = nil,
                background: LinkBackground? = nil) {
        self.id = id
        self.draft = draft
        self.createdAt = createdAt
        self.readUpTo = readUpTo
        self.archivedAt = archivedAt
        self.background = background
    }
}

/// A bot or group, by its ID, to archive or bring back.
public struct LinkArchiveChange: Codable, Equatable, Sendable {
    public var id: UUID
    public var archived: Bool

    public init(id: UUID, archived: Bool) {
        self.id = id
        self.archived = archived
    }
}

/// What a device away from the Hub listens on for unread replies. Only the Hub and the device know it.
public struct LinkPushTopic: Codable, Equatable, Sendable {
    public var topic: String?

    public init(topic: String?) {
        self.topic = topic
    }
}

/// Where a Hub leaves word of unread replies for devices that are away: records in CloudKit's
/// public database, one per device and conversation, which a device subscribes to by its topic.
public enum LinkPush {
    public static let container = "iCloud.com.pdparchitect.noodle"
    public static let recordType = "Ping"
    public static let topicField = "topic"
    public static let conversationField = "conversation"
    public static let unreadField = "unread"
}

/// How far a device has read a conversation: up to and including a message. It names the message
/// rather than its date, since a date that crossed the link may no longer match the Hub's exactly.
public struct LinkReadMark: Codable, Equatable, Sendable {
    public var conversationID: UUID
    public var messageID: UUID

    public init(conversationID: UUID, messageID: UUID) {
        self.conversationID = conversationID
        self.messageID = messageID
    }
}

/// What a bot's harness is doing, as Noodle's runtime reports it.
/// What Kick asks before restarting a bot whose failure needs the person to agree, in the
/// Hub's words, so every device asks the same as Noodle does.
public struct LinkKickConfirmation: Codable, Equatable, Sendable {
    /// Named in `confirmKick`; it works once, and only while the bot fails the same way.
    public var id: UUID
    public var title: String
    public var message: String
    /// The button that agrees.
    public var confirmTitle: String
    /// Whether New Session is offered beside it.
    public var offersNewSession: Bool

    public init(id: UUID, title: String, message: String, confirmTitle: String, offersNewSession: Bool) {
        self.id = id
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.offersNewSession = offersNewSession
    }
}

public enum LinkBotPhase: String, Codable, Sendable {
    case offline, starting, ready, working, failed
}

/// One person's or bot's reaction to a message.
public struct LinkReaction: Codable, Hashable, Sendable {
    public var author: LinkMessage.Author
    public var emoji: String

    public init(author: LinkMessage.Author, emoji: String) {
        self.author = author
        self.emoji = emoji
    }
}

/// Adds or removes the sender's reaction.
public struct LinkReactionChange: Codable, Equatable, Sendable {
    public var conversationID: UUID
    public var messageID: UUID
    public var emoji: String
    public var present: Bool

    public init(conversationID: UUID, messageID: UUID, emoji: String, present: Bool) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.emoji = emoji
        self.present = present
    }
}

public struct LinkMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Author: Codable, Hashable, Sendable {
        case you, bot(UUID), system
    }

    public var id: UUID
    public var conversationID: UUID
    public var author: Author
    public var body: String
    public var createdAt: Date
    /// Whether the bot has taken the message yet.
    public var delivered: Bool
    public var attachments: [LinkAttachment]
    public var reactions: [LinkReaction]
    /// Set on the message that marks where a voice call started.
    public var call: LinkCallRecord?

    public init(id: UUID, conversationID: UUID, author: Author, body: String, createdAt: Date, delivered: Bool,
                attachments: [LinkAttachment] = [], reactions: [LinkReaction] = [], call: LinkCallRecord? = nil) {
        self.attachments = attachments
        self.reactions = reactions
        self.call = call
        self.id = id
        self.conversationID = conversationID
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.delivered = delivered
    }

    private enum CodingKeys: String, CodingKey { case id, conversationID, author, body, createdAt, delivered, attachments, reactions, call }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        author = try c.decode(Author.self, forKey: .author)
        body = try c.decode(.body, or: "")
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        delivered = try c.decode(.delivered, or: false)
        attachments = try c.decode(.attachments, or: [])
        reactions = try c.decode(.reactions, or: [])
        call = try c.decodeIfPresent(LinkCallRecord.self, forKey: .call)
    }
}

/// A file in a conversation.
public struct LinkAttachment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var filename: String
    public var mediaType: String
    public var byteCount: Int
    /// Set when the file is a voice message.
    public var voice: LinkVoice?
    /// Set for a link, which travels as its address rather than as a file: a web page, or a
    /// browser tab, computer or noodlet, which opens live.
    public var url: URL?
    /// What a link to a browser tab, computer or noodlet shows.
    public var card: LinkCardInfo?
    /// Set for a picture, so a device holds its place before the file arrives.
    public var pixelSize: LinkPixelSize?

    public init(id: UUID, filename: String, mediaType: String, byteCount: Int, voice: LinkVoice? = nil,
                url: URL? = nil, card: LinkCardInfo? = nil, pixelSize: LinkPixelSize? = nil) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.voice = voice
        self.url = url
        self.card = card
        self.pixelSize = pixelSize
    }

    private enum CodingKeys: String, CodingKey { case id, filename, mediaType, byteCount, voice, url, card, pixelSize }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(.filename, or: "Attachment")
        mediaType = try c.decode(.mediaType, or: "application/octet-stream")
        byteCount = try c.decode(Int.self, forKey: .byteCount)
        voice = try c.decodeIfPresent(LinkVoice.self, forKey: .voice)
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        card = try c.decodeIfPresent(LinkCardInfo.self, forKey: .card)
        // Only a hint: a size that makes no sense is left out rather than failing the message.
        pixelSize = try? c.decodeIfPresent(LinkPixelSize.self, forKey: .pixelSize)
    }
}

/// A picture's size in pixels, as it is shown once turned upright.
public struct LinkPixelSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    /// Larger than any picture a conversation holds.
    private static let limit = 100_000

    public init?(width: Int, height: Int) {
        guard (1...Self.limit).contains(width), (1...Self.limit).contains(height) else { return nil }
        self.width = width
        self.height = height
    }

    /// Reads only the file's header; nil for anything that is not a picture.
    public init?(pictureAt url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        // Orientations 5 to 8 turn the picture a quarter.
        let turned = (5...8).contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
        self.init(width: turned ? height : width, height: turned ? width : height)
    }

    private enum CodingKeys: String, CodingKey { case width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let size = Self(width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height)) else {
            throw DecodingError.dataCorruptedError(forKey: .width, in: c, debugDescription: "Not a picture's size")
        }
        self = size
    }
}

/// The label and last picture of a link to something live, as shared in the conversation.
public struct LinkCardInfo: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String?
    public var image: Data?
    public var symbol: String?
    public var colour: Int?
    public var icon: Data?
    public var capturedAt: Date?

    public init(title: String, detail: String? = nil, image: Data? = nil, symbol: String? = nil, colour: Int? = nil,
                icon: Data? = nil, capturedAt: Date? = nil) {
        self.title = title
        self.detail = detail
        self.image = image
        self.symbol = symbol
        self.colour = colour
        self.icon = icon
        self.capturedAt = capturedAt
    }
}

/// What a voice message said and how it sounded, so bots read the words and devices draw the waveform.
public struct LinkVoice: Codable, Equatable, Sendable {
    public var transcript: String?
    public var duration: Double
    /// Levels from 0 to 1 across the recording.
    public var waveform: [Float]
    public var localeIdentifier: String?

    public init(transcript: String?, duration: Double, waveform: [Float], localeIdentifier: String?) {
        self.transcript = transcript
        self.duration = duration
        self.waveform = waveform
        self.localeIdentifier = localeIdentifier
    }
}

/// A message a device sends. `id` is chosen by the device, so a retried send is not doubled.
public struct LinkOutgoingMessage: Codable, Equatable, Sendable {
    public var conversationID: UUID
    public var id: UUID
    public var body: String
    public var attachmentIDs: [UUID]

    public init(conversationID: UUID, id: UUID, body: String, attachmentIDs: [UUID] = []) {
        self.conversationID = conversationID
        self.id = id
        self.body = body
        self.attachmentIDs = attachmentIDs
    }

    private enum CodingKeys: String, CodingKey { case conversationID, id, body, attachmentIDs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        id = try c.decode(UUID.self, forKey: .id)
        body = try c.decode(String.self, forKey: .body)
        attachmentIDs = try c.decode(.attachmentIDs, or: [])
    }
}

/// Messages from a position on, and how many the conversation holds in all.
public struct LinkMessages: Codable, Equatable, Sendable {
    public var messages: [LinkMessage]
    public var count: Int
    /// Where the first of `messages` sits in the conversation, for a page.
    public var start: Int?

    public init(messages: [LinkMessage], count: Int, start: Int? = nil) {
        self.messages = messages
        self.count = count
        self.start = start
    }
}

/// Which part of a conversation a device wants: up to `limit` messages before position `before`,
/// the newest when it is nil, or from `after` on when it is set. A page may hold fewer, to stay small.
public struct LinkMessagePage: Codable, Equatable, Sendable {
    public var conversationID: UUID
    public var before: Int?
    public var after: Int?
    public var limit: Int

    public init(conversationID: UUID, before: Int? = nil, after: Int? = nil, limit: Int = 50) {
        self.conversationID = conversationID
        self.before = before
        self.after = after
        self.limit = limit
    }
}

/// Everything a device needs to find a Hub, trust it and pair once.
public struct LinkInvitation: Codable, Equatable, Sendable {
    public static let lifetime: TimeInterval = 15 * 60
    public static let urlHost = "join-hub"

    public var hubName: String
    public var hubKey: LinkPublicKey
    public var endpoints: [LinkEndpoint]
    public var userName: String
    /// The private half of a key made for this invitation alone. A joining device presents it in
    /// the handshake; the Hub lets no other unpaired key connect.
    public var joinKey: Data
    public var expires: Date
    /// The request version the inviting Hub speaks.
    public var version: Int

    private enum CodingKeys: String, CodingKey { case hubName, hubKey, endpoints, userName, joinKey, expires, version }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hubName = try c.decode(.hubName, or: "Noodle Hub")
        hubKey = try c.decode(LinkPublicKey.self, forKey: .hubKey)
        endpoints = try c.decode(.endpoints, or: [])
        userName = try c.decode(.userName, or: "")
        joinKey = try c.decode(Data.self, forKey: .joinKey)
        expires = try c.decode(Date.self, forKey: .expires)
        version = try c.decode(.version, or: 1)
    }

    public init(hubName: String, hubKey: LinkPublicKey, endpoints: [LinkEndpoint], userName: String, joinKey: Data, expires: Date,
                version: Int = LinkProtocol.version) {
        self.version = version
        self.hubName = hubName
        self.hubKey = hubKey
        self.endpoints = endpoints
        self.userName = userName
        self.joinKey = joinKey
        self.expires = expires
    }

    /// What the joining device connects as, until it has paired its own key.
    public func joinIdentity() throws -> LinkIdentity {
        LinkIdentity(privateKey: try P256.Signing.PrivateKey(rawRepresentation: joinKey))
    }

    /// A link Noodle opens, which is also what the QR code holds.
    public func url(scheme: String = "noodle") -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = Self.urlHost
        components.queryItems = [URLQueryItem(name: "i", value: encoded)]
        return components.url!
    }

    /// Reads a link from any Noodle build, or the bare code inside it.
    public init(text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = URLComponents(string: text).flatMap { components in
            components.host == Self.urlHost ? components.queryItems?.first { $0.name == "i" }?.value : nil
        } ?? text
        guard let data = Data(base64URL: code), let invitation = try? Self.decoder.decode(Self.self, from: data),
              (try? invitation.joinIdentity()) != nil else {
            throw LinkError("This is not a Noodle Hub invitation.")
        }
        guard LinkProtocol.supportedVersions.contains(invitation.version) else {
            throw LinkError(invitation.version > LinkProtocol.version
                            ? "This invitation needs a newer Noodle. Update Noodle." : "This invitation is from an older Noodle Hub. Update Noodle Hub.")
        }
        self = invitation
    }

    private var encoded: String { (try! Self.encoder.encode(self)).base64URL }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}

extension KeyedDecodingContainer {
    /// A field that may be missing, as when it was added after the sender was built.
    func decode<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}
