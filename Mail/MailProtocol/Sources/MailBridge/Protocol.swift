import Foundation

/// A failure a person or bot can act on. `unavailable` means Noodle Mail could not be reached,
/// so the caller may start it and try again.
public struct MailError: LocalizedError, Equatable, Sendable {
    public let message: String
    public let unavailable: Bool
    public init(_ message: String, unavailable: Bool = false) {
        self.message = message
        self.unavailable = unavailable
    }
    public var errorDescription: String? { message }
}

/// What Noodle and its Mail tool extension may ask of Noodle Mail. Only `read` with `markRead` changes a mailbox.
public enum MailOperation: String, Codable, CaseIterable, Sendable {
    case mailboxes, folders, list, search, read, attachment

    /// Seconds the socket waits for an answer: mail servers can be slow, and attachments are large.
    public var timeout: Int { self == .attachment ? 180 : 60 }
}

public enum MailLimits {
    /// The largest attachment handed over. Its base64 stays under the 32 MiB frame.
    public static let attachmentBytes = 20 * 1_048_576
    /// How much of a message's text `read` returns unless asked otherwise.
    public static let defaultCharacters = 20_000
    public static let characters = 1_000...200_000
    /// IMAP UIDs are 32-bit; the largest value means "*" to a server, so it is never a message.
    public static let uids = 1...4_294_967_294
    public static let rows = 1...100
}

/// Filters for `list` and `search`. Every filter given must match.
public struct MailQuery: Codable, Equatable, Sendable {
    public var unreadOnly: Bool?
    public var from: String?
    public var to: String?
    public var subject: String?
    public var text: String?
    /// Days as YYYY-MM-DD. `since` includes its day and `before` excludes it, as in IMAP.
    public var since: String?
    public var before: String?
    /// Only older messages: the next page after the last UID a bot has seen.
    public var beforeUID: Int?
    public var limit: Int?
    public init() {}
}

public struct MailRequest: Codable, Sendable {
    public var version = 1
    public var id = UUID()
    public var operation: MailOperation
    public var mailboxID: UUID?
    /// The server's raw folder name, exactly as `folders` returns it; INBOX when absent.
    public var folder: String?
    public var query: MailQuery?
    public var uid: Int?
    /// An attachment's part number, as `read` lists it.
    public var part: String?
    public var markRead: Bool?
    public var maxCharacters: Int?

    public init(_ operation: MailOperation, mailboxID: UUID? = nil) {
        self.operation = operation
        self.mailboxID = mailboxID
    }

    /// Decodes a request. One this build can't read comes from a newer Noodle.
    public static func read(_ data: Data) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw MailError("This needs a newer \(MailBuildIdentity.current.appName). Update it.") }
    }

    /// Refuses anything malformed before it can reach a mail server. Control characters are refused
    /// everywhere because folder names and search text end up inside IMAP commands.
    public func validate() throws {
        guard version == 1 else { throw MailError("This needs a newer \(MailBuildIdentity.current.appName). Update it.") }
        if operation != .mailboxes, mailboxID == nil { throw MailError("Specify a mailbox.") }
        if let folder { try Self.check(folder, "folder name") }
        if let query {
            for value in [query.from, query.to, query.subject, query.text].compactMap({ $0 }) {
                try Self.check(value, "search text", allowEmpty: true)
            }
            for day in [query.since, query.before].compactMap({ $0 }) where Self.day(day) == nil {
                throw MailError("Use YYYY-MM-DD for dates.")
            }
            if let beforeUID = query.beforeUID, !MailLimits.uids.contains(beforeUID) { throw MailError("Invalid message UID.") }
            if let limit = query.limit, !MailLimits.rows.contains(limit) { throw MailError("The limit must be 1 to 100.") }
        }
        if let uid, !MailLimits.uids.contains(uid) { throw MailError("Invalid message UID.") }
        if operation == .read || operation == .attachment, uid == nil { throw MailError("Specify the message UID.") }
        if let part, !Self.isPart(part) { throw MailError("Invalid attachment part.") }
        if operation == .attachment, part == nil { throw MailError("Specify the attachment part from read.") }
        if let maxCharacters, !MailLimits.characters.contains(maxCharacters) {
            throw MailError("max_chars must be 1000 to 200000.")
        }
    }

    /// 12:00 UTC on a YYYY-MM-DD day, so the day stays the same in any European time zone.
    public static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.utf8.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        return check.year == year && check.month == month && check.day == day ? date : nil
    }

    private static func check(_ value: String, _ what: String, allowEmpty: Bool = false) throws {
        guard allowEmpty || !value.isEmpty, value.utf8.count <= 1_000,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw MailError("Invalid \(what).")
        }
    }

    private static func isPart(_ part: String) -> Bool {
        part.utf8.count <= 64 && part.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }
    }
}

/// A mailbox as Noodle and bots see it: never its servers, username or password.
public struct RemoteMailbox: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var address: String
    public init(id: UUID, name: String, address: String) {
        self.id = id
        self.name = name
        self.address = address
    }
}

public struct MailFolderInfo: Codable, Equatable, Sendable {
    /// The server's raw name. Every call that takes a folder wants it unchanged.
    public let name: String
    /// The name decoded for reading: "Odeslané" for "Odeslan&AOk-".
    public let display: String
    /// inbox, drafts, sent, trash, junk or archive, when the server says so.
    public let role: String?
    public init(name: String, display: String, role: String?) {
        self.name = name
        self.display = display
        self.role = role
    }
}

public struct MailMessageRow: Codable, Equatable, Sendable {
    public let uid: Int
    /// ISO 8601.
    public let date: String?
    public let from: String?
    public let subject: String?
    public let seen: Bool
    public let attachments: Int
    public init(uid: Int, date: String?, from: String?, subject: String?, seen: Bool, attachments: Int) {
        self.uid = uid
        self.date = date
        self.from = from
        self.subject = subject
        self.seen = seen
        self.attachments = attachments
    }
}

public struct MailAttachmentInfo: Codable, Equatable, Sendable {
    public let part: String
    public let name: String
    public let type: String
    /// Bytes as the server reports them, when it does.
    public let size: Int?
    public init(part: String, name: String, type: String, size: Int?) {
        self.part = part
        self.name = name
        self.type = type
        self.size = size
    }
}

public struct MailMessage: Codable, Equatable, Sendable {
    public let uid: Int
    public let from: String?
    public let to: [String]
    public let cc: [String]
    /// ISO 8601.
    public let date: String?
    public let subject: String?
    public let messageId: String?
    /// Plain text; HTML-only mail arrives converted.
    public let text: String
    /// True when `text` was cut at the requested number of characters.
    public let truncated: Bool
    public let attachments: [MailAttachmentInfo]
    /// How many attachments came after the ones listed and were left out; absent when none were.
    public let attachmentsOmitted: Int?
    public init(uid: Int, from: String?, to: [String], cc: [String], date: String?, subject: String?, messageId: String?,
                text: String, truncated: Bool, attachments: [MailAttachmentInfo], attachmentsOmitted: Int? = nil) {
        self.uid = uid
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.subject = subject
        self.messageId = messageId
        self.text = text
        self.truncated = truncated
        self.attachments = attachments
        self.attachmentsOmitted = attachmentsOmitted
    }
}

public struct MailAttachmentData: Codable, Equatable, Sendable {
    public let data: Data
    public init(data: Data) { self.data = data }
}

public struct MailResponse: Codable, Sendable {
    public var version = 1
    public var mailboxes: [RemoteMailbox]?
    public var folders: [MailFolderInfo]?
    public var messages: [MailMessageRow]?
    public var message: MailMessage?
    public var attachment: MailAttachmentData?
    public var error: String?
    public init(error: String? = nil) { self.error = error }

    /// The response, or its error thrown as a `MailError`.
    public func checked() throws -> Self {
        if let error { throw MailError(error) }
        guard version == 1 else { throw MailError("This needs a newer Noodle. Update it.") }
        return self
    }
}
