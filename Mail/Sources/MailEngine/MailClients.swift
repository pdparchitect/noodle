import Foundation
import SwiftMail

/// Headers and structure of one message, without its content.
struct HeaderRecord: Equatable, Sendable {
    let uid: Int
    let date: Date?
    let from: String?
    let to: [String]
    let cc: [String]
    let subject: String?
    let messageId: String?
    let seen: Bool
    let parts: [PartRecord]

    init(uid: Int, date: Date?, from: String?, to: [String], cc: [String], subject: String?, messageId: String?, seen: Bool, parts: [PartRecord]) {
        self.uid = uid
        self.date = date
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.messageId = messageId
        self.seen = seen
        self.parts = parts
    }
}

extension FolderRole {
    /// A folder's role. A server that advertises SPECIAL-USE marks its folders itself, so only its marks count and a folder it didn't
    /// mark has none. Without SPECIAL-USE, marks are SwiftMail's guesses from parts of names ("Presentations" passes for Sent), so they
    /// are ignored, and only a well-known English name, matched whole and in any case against the last part of the path, gives a role.
    init?(attributes: Mailbox.Info.Attributes, name: String, delimiter: String?, serverMarksRoles: Bool) {
        let role = serverMarksRoles ? Self.marked(attributes) : Self.wellKnownNames[Self.lastComponent(of: name, delimiter: delimiter).lowercased()]
        guard let role else { return nil }
        self = role
    }

    private static func marked(_ attributes: Mailbox.Info.Attributes) -> FolderRole? {
        if attributes.contains(.inbox) { return .inbox }
        if attributes.contains(.drafts) { return .drafts }
        if attributes.contains(.sent) { return .sent }
        if attributes.contains(.trash) { return .trash }
        if attributes.contains(.junk) { return .junk }
        if attributes.contains(.archive) { return .archive }
        return nil
    }

    private static let wellKnownNames: [String: FolderRole] = [
        "inbox": .inbox, "drafts": .drafts, "sent": .sent, "sent items": .sent, "sent messages": .sent,
        "trash": .trash, "deleted items": .trash, "junk": .junk, "spam": .junk, "archive": .archive,
    ]

    private static func lastComponent(of name: String, delimiter: String?) -> String {
        guard let delimiter, !delimiter.isEmpty else { return name }
        return name.components(separatedBy: delimiter).last ?? name
    }
}

/// The IMAP operations the engine uses. The real one is SwiftMail; tests use a fake.
protocol IMAPClient: AnyObject {
    func login(username: String, password: String) async throws
    /// Every folder by the name the server uses, which is also the name to pass back.
    func folders() async throws -> [MailFolder]
    func select(_ folder: String) async throws
    /// UIDs matching all terms, ascending.
    func search(_ terms: [SearchTerm]) async throws -> [Int]
    func headers(_ uids: [Int]) async throws -> [HeaderRecord]
    /// A part's bytes with the transfer encoding (base64, quoted-printable) undone; the charset is left to the caller.
    func partData(uid: Int, section: String) async throws -> Data
    func markSeen(uid: Int) async throws
    /// Files these exact bytes as a message; the UID it got, when the server says.
    func append(_ message: Data, to folder: String, flags: [Flag]) async throws -> Int?
    func logout() async
}

/// The SMTP operations the engine uses.
protocol SMTPClient: AnyObject {
    func login(username: String, password: String) async throws
    /// Sends these exact bytes to the envelope recipients.
    func send(_ message: Data, from sender: EmailAddress, to recipients: [EmailAddress]) async throws
    func logout() async
}

final class SwiftMailIMAPClient: IMAPClient {
    private let server: IMAPServer

    init(_ config: MailServer) throws {
        server = IMAPServer(host: config.host, port: config.port, transportSecurity: try config.transportSecurity())
    }

    func login(username: String, password: String) async throws {
        try await server.connect()
        try await server.login(username: username, password: password)
    }

    func folders() async throws -> [MailFolder] {
        // SwiftMail keeps the capabilities from greeting and sign-in to itself, and empties them when it recycles a connection. Asking on
        // every call, right before the listing, reconnects such a connection and refreshes them; the listing then makes its own SPECIAL-USE
        // test on that very answer. A cached answer could say yes while the listing finds none and guesses. The test here is SwiftMail's
        // exact one, so the two never disagree.
        let marksRoles = try await server.fetchCapabilities().contains { String($0) == "SPECIAL-USE" }
        // Returns only the special folders, but lists every folder first and keeps that list in `mailboxes`.
        let special = try await server.listSpecialUseMailboxes()
        return Self.folders(await server.mailboxes, special: special, serverMarksRoles: marksRoles)
    }

    /// Every folder the server lists, marked or not, since an account's folder override has to be one of these names exactly as the
    /// server sends them. On a server that marks roles, the marks come from its special-use listing, which a plain listing may leave out.
    static func folders(_ listed: [Mailbox.Info], special: [Mailbox.Info], serverMarksRoles: Bool) -> [MailFolder] {
        listed.map { mailbox in
            let attributes = special.first { $0.name == mailbox.name }?.attributes ?? mailbox.attributes
            return MailFolder(name: mailbox.name, role: FolderRole(attributes: attributes, name: mailbox.name,
                                                                   delimiter: mailbox.hierarchyDelimiter, serverMarksRoles: serverMarksRoles))
        }
    }

    func select(_ folder: String) async throws { try await server.selectMailbox(folder) }

    func search(_ terms: [SearchTerm]) async throws -> [Int] {
        let result: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: terms.map(Self.criteria))
        return (result.all?.toArray() ?? []).map { Int($0.value) }
    }

    func headers(_ uids: [Int]) async throws -> [HeaderRecord] {
        // SwiftMail stops the process on an empty set, so the check comes after impossible UIDs are dropped.
        let set = UIDSet(uids.compactMap(Self.uid))
        guard !set.isEmpty else { return [] }
        return try await server.fetchMessageInfosBulk(using: set).compactMap(Self.record)
    }

    func partData(uid: Int, section: String) async throws -> Data {
        guard let id = Self.uid(uid), let info = try await server.fetchMessageInfo(for: id) else { throw MailEngineError.messageNotFound(uid: uid) }
        guard let part = info.parts.first(where: { $0.section.description == section }) else { throw MailEngineError.partNotFound(uid: uid, part: section) }
        return try await server.fetchAndDecodeMessagePartData(messageInfo: info, part: part)
    }

    func markSeen(uid: Int) async throws {
        guard let id = Self.uid(uid) else { throw MailEngineError.messageNotFound(uid: uid) }
        try await server.store(flags: [.seen], on: UIDSet(id), operation: .add)
    }

    func append(_ message: Data, to folder: String, flags: [Flag]) async throws -> Int? {
        // SwiftMail takes the raw message as a String and writes it back out as UTF-8, so bytes that came from a String pass unchanged.
        try await server.append(rawMessage: String(decoding: message, as: UTF8.self), to: folder, flags: flags, internalDate: nil)
            .firstUID.map { Int($0.value) }
    }

    func logout() async { try? await server.logout() }

    /// The UID for a number a bot passed, nil when it can't ask for one message: UIDs start at 1, the IMAP library writes 2³²−1 as `*`
    /// (the newest message), and converting a number past 32 bits would stop the process.
    private static func uid(_ value: Int) -> UID? {
        guard value > 0, value < Int(UInt32.max) else { return nil }
        return UID(UInt32(value))
    }

    private static func criteria(_ term: SearchTerm) -> SearchCriteria {
        switch term {
        case .all: return .all
        case .unseen: return .unseen
        case .from(let value): return .from(value)
        case .to(let value): return .to(value)
        case .subject(let value): return .subject(value)
        case .text(let value): return .text(value)
        case .since(let date): return .since(date)
        case .before(let date): return .before(date)
        }
    }

    private static func record(_ info: MessageInfo) -> HeaderRecord? {
        guard let uid = info.uid else { return nil }
        return HeaderRecord(uid: Int(uid.value), date: info.date, from: info.from, to: info.to, cc: info.cc, subject: info.subject,
                            messageId: info.messageId.map { "\($0)" }, seen: info.flags.contains(.seen), parts: info.parts.map(PartRecord.init))
    }
}

final class SwiftMailSMTPClient: SMTPClient {
    private let server: SMTPServer

    init(_ config: MailServer) throws {
        server = SMTPServer(host: config.host, port: config.port, transportSecurity: try config.transportSecurity())
    }

    func login(username: String, password: String) async throws {
        try await server.connect()
        try await server.login(username: username, password: password)
    }

    func send(_ message: Data, from sender: EmailAddress, to recipients: [EmailAddress]) async throws {
        try await server.sendRawMessage(message, from: sender, to: recipients)
    }

    func logout() async { try? await server.disconnect() }
}
