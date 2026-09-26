import CryptoKit
import Foundation

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

    public static func encode(_ request: LinkRequest) throws -> Data {
        try encoder.encode(Envelope(version: version, request: request))
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
            return .failure(LinkError("This Noodle Hub does not know that request. Update Noodle Hub."))
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

    private struct Header: Decodable { var version: Int }
    private struct Envelope: Codable {
        var version: Int
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
    /// Pairs the key this request arrives with to the invitation's user. The token works once.
    case enroll(token: String, deviceName: String)
    /// What the Hub lends this device's user.
    case status
    /// Keeps a stream open that the Hub pushes `LinkEvent`s down.
    case subscribe
    /// This user's bots on the Hub.
    case bots
    case createBot(LinkBotDraft)
    case updateBot(id: UUID, LinkBotDraft)
    case deleteBot(id: UUID)
    /// Messages of one of this user's conversations, from position `after` on.
    case messages(conversationID: UUID, after: Int)
    /// Sends as this user. Attachments are uploaded first.
    case send(LinkOutgoingMessage)
    /// One piece of a file for a conversation, starting at `offset`. Pieces go in order.
    case upload(conversationID: UUID, attachment: LinkAttachment, offset: Int, data: Data)
    /// One piece of a conversation's file, starting at `offset`.
    case download(conversationID: UUID, attachmentID: UUID, offset: Int)
    /// Adds or removes this user's reaction to a message. Answers with the message.
    case react(LinkReactionChange)
    /// This user's tool connections on the Hub.
    case connections
    /// Adds a connection, or changes one of this user's. It reaches no bot until assigned.
    case saveConnection(LinkConnectionDraft)
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
}

public enum LinkResponse: Codable, Equatable, Sendable {
    case status(LinkStatus)
    case bots([LinkBot])
    case bot(LinkBot)
    case messages(LinkMessages)
    case message(LinkMessage)
    case connections([LinkConnection])
    case connection(LinkConnection)
    case computers([LinkComputer])
    case computer(LinkComputer)
    case computerTemplates([LinkComputerTemplate])
    /// A piece of a file, and the file's full size.
    case chunk(data: Data, total: Int)
    case done
    case failure(String)
}

/// Pushed down a subscription. Devices fetch what changed with ordinary requests.
public enum LinkEvent: Codable, Equatable, Sendable {
    case conversationChanged(conversationID: UUID, count: Int)
    case botsChanged
    /// A message already sent changed, as when someone reacted to it.
    case messageChanged(LinkMessage)
    /// What a bot is doing now.
    case botPhase(botID: UUID, phase: LinkBotPhase)
    /// This user's connections, their sign-in or their bots changed.
    case connectionsChanged
    /// Open this page in the browser to sign a connection in, then send `finishSignIn`.
    case signInPage(connectionID: UUID, url: URL)
    /// This user's computers or their bots changed.
    case computersChanged
    /// A computer asked for with `createComputer` was made, or why it was not.
    case computerCreated(requestID: UUID, computer: LinkComputer?, error: String?)
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

/// A tool connection one user keeps on the Hub.
public struct LinkConnection: Codable, Equatable, Identifiable, Sendable {
    public var draft: LinkConnectionDraft
    public var iconData: Data?
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

    public init(hubName: String, userName: String, planName: String, harnesses: [LinkHarness], endpoints: [LinkEndpoint],
                protocolVersion: Int = LinkProtocol.version) {
        self.hubName = hubName
        self.userName = userName
        self.planName = planName
        self.harnesses = harnesses
        self.endpoints = endpoints
        self.protocolVersion = protocolVersion
    }

    private enum CodingKeys: String, CodingKey { case hubName, userName, planName, harnesses, endpoints, protocolVersion }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hubName = try c.decode(String.self, forKey: .hubName)
        userName = try c.decode(.userName, or: "")
        planName = try c.decode(.planName, or: "")
        harnesses = try c.decode(.harnesses, or: [])
        endpoints = try c.decode(.endpoints, or: [])
        protocolVersion = try c.decode(.protocolVersion, or: 1)
    }
}

/// A harness login the Hub lends. `profile` and `profileName` are nil for the harness's own login.
public struct LinkHarness: Codable, Hashable, Sendable {
    public var provider: String
    public var providerName: String
    public var profile: UUID?
    public var profileName: String?

    public init(provider: String, providerName: String, profile: UUID? = nil, profileName: String?) {
        self.provider = provider
        self.providerName = providerName
        self.profile = profile
        self.profileName = profileName
    }

    private enum CodingKeys: String, CodingKey { case provider, providerName, profile, profileName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        providerName = try c.decode(.providerName, or: provider)
        profile = try c.decodeIfPresent(UUID.self, forKey: .profile)
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
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
        case name, provider, profile, model, reasoningEffort, publicDescription, backstory, avatarSymbolName, avatarColorIndex, avatarImageData
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
    }
}

/// A bot on the Hub and its conversation with its owner.
public struct LinkBot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var conversationID: UUID
    public var draft: LinkBotDraft
    public var createdAt: Date
    /// What it was doing when listed. Nil from a Hub that does not say, or in a way this app does not know.
    public var phase: LinkBotPhase?

    public init(id: UUID, conversationID: UUID, draft: LinkBotDraft, createdAt: Date, phase: LinkBotPhase? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.draft = draft
        self.createdAt = createdAt
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey { case id, conversationID, draft, createdAt, phase }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        draft = try c.decode(LinkBotDraft.self, forKey: .draft)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        phase = try c.decodeIfPresent(String.self, forKey: .phase).flatMap(LinkBotPhase.init(rawValue:))
    }
}

/// What a bot's harness is doing, as Noodle's runtime reports it.
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

    public init(id: UUID, conversationID: UUID, author: Author, body: String, createdAt: Date, delivered: Bool,
                attachments: [LinkAttachment] = [], reactions: [LinkReaction] = []) {
        self.attachments = attachments
        self.reactions = reactions
        self.id = id
        self.conversationID = conversationID
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.delivered = delivered
    }

    private enum CodingKeys: String, CodingKey { case id, conversationID, author, body, createdAt, delivered, attachments, reactions }

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

    public init(id: UUID, filename: String, mediaType: String, byteCount: Int, voice: LinkVoice? = nil) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.voice = voice
    }

    private enum CodingKeys: String, CodingKey { case id, filename, mediaType, byteCount, voice }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(.filename, or: "Attachment")
        mediaType = try c.decode(.mediaType, or: "application/octet-stream")
        byteCount = try c.decode(Int.self, forKey: .byteCount)
        voice = try c.decodeIfPresent(LinkVoice.self, forKey: .voice)
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

    public init(messages: [LinkMessage], count: Int) {
        self.messages = messages
        self.count = count
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
    public var token: String
    public var expires: Date
    /// The request version the inviting Hub speaks.
    public var version: Int

    private enum CodingKeys: String, CodingKey { case hubName, hubKey, endpoints, userName, token, expires, version }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hubName = try c.decode(.hubName, or: "Noodle Hub")
        hubKey = try c.decode(LinkPublicKey.self, forKey: .hubKey)
        endpoints = try c.decode(.endpoints, or: [])
        userName = try c.decode(.userName, or: "")
        token = try c.decode(String.self, forKey: .token)
        expires = try c.decode(Date.self, forKey: .expires)
        version = try c.decode(.version, or: 1)
    }

    public init(hubName: String, hubKey: LinkPublicKey, endpoints: [LinkEndpoint], userName: String, token: String, expires: Date,
                version: Int = LinkProtocol.version) {
        self.version = version
        self.hubName = hubName
        self.hubKey = hubKey
        self.endpoints = endpoints
        self.userName = userName
        self.token = token
        self.expires = expires
    }

    public static func newToken() -> String {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }).base64URL
    }

    /// What the Hub keeps instead of the token itself.
    public static func tokenDigest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
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
        guard let data = Data(base64URL: code), let invitation = try? Self.decoder.decode(Self.self, from: data) else {
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
