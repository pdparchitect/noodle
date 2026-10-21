import Foundation

/// Which messages to list: all criteria must match. Paging goes backwards from `beforeUID`.
public struct MessageQuery: Equatable, Sendable {
    /// The server's raw folder name, exactly as `MailSession.folders()` returns it (modified UTF-7, e.g. "Odeslan&AOk-").
    public var folder = "INBOX"
    public var unreadOnly = false
    public var from: String?
    public var to: String?
    public var subject: String?
    public var text: String?
    public var since: Date?
    public var before: Date?
    public var beforeUID: Int?
    public var limit = 20

    public init() {}

    /// The page size actually used: at least one message, at most a hundred.
    public var clampedLimit: Int { min(max(limit, 1), 100) }
}

/// One line in a message list.
public struct MessageRow: Codable, Equatable, Sendable {
    public let uid: Int
    public let date: Date?
    public let from: String?
    public let subject: String?
    public let seen: Bool
    public let attachments: Int

    public init(uid: Int, date: Date?, from: String?, subject: String?, seen: Bool, attachments: Int) {
        self.uid = uid
        self.date = date
        self.from = from
        self.subject = subject
        self.seen = seen
        self.attachments = attachments
    }
}

/// An attachment a bot can save by its part number.
public struct AttachmentInfo: Codable, Equatable, Sendable {
    public let part: String
    public let name: String
    public let type: String
    public let size: Int?

    public init(part: String, name: String, type: String, size: Int?) {
        self.part = part
        self.name = name
        self.type = type
        self.size = size
    }
}

/// A message as a bot reads it: headers, plain text, and its attachments without their data.
public struct MessageDetail: Codable, Equatable, Sendable {
    public let uid: Int
    public let from: String?
    public let to: [String]
    public let cc: [String]
    public let date: Date?
    public let subject: String?
    public let messageId: String?
    public let text: String
    public let attachments: [AttachmentInfo]
    /// How many attachments came after the ones listed and were left out; nil when none were.
    public let attachmentsOmitted: Int?

    public init(uid: Int, from: String?, to: [String], cc: [String], date: Date?, subject: String?, messageId: String?,
                text: String, attachments: [AttachmentInfo], attachmentsOmitted: Int? = nil) {
        self.uid = uid
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.subject = subject
        self.messageId = messageId
        self.text = text
        self.attachments = attachments
        self.attachmentsOmitted = attachmentsOmitted
    }
}

/// A file to attach to an outgoing mail.
public struct OutgoingAttachment: Equatable, Sendable {
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// A mail a bot wants drafted or sent. Addresses are "Name <a@b.cz>" or "a@b.cz".
public struct OutgoingMail: Equatable, Sendable {
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String
    /// Message-ID of the mail being answered, so the reply threads.
    public var inReplyTo: String?
    public var attachments: [OutgoingAttachment]

    public init(to: [String], cc: [String] = [], bcc: [String] = [], subject: String, body: String,
                inReplyTo: String? = nil, attachments: [OutgoingAttachment] = []) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.attachments = attachments
    }
}

/// Where a draft was saved. The UID is missing when the server doesn't report it (no UIDPLUS).
public struct DraftReceipt: Codable, Equatable, Sendable {
    public let draftUid: Int?
    public let folder: String

    public init(draftUid: Int?, folder: String) {
        self.draftUid = draftUid
        self.folder = folder
    }
}

/// A mail that went out. `savedToSent` is false when the copy in Sent could not be stored; the mail was still sent.
public struct SendReceipt: Codable, Equatable, Sendable {
    public let messageId: String
    public let savedToSent: Bool

    public init(messageId: String, savedToSent: Bool) {
        self.messageId = messageId
        self.savedToSent = savedToSent
    }
}

/// What a folder is for, when the server says so.
public enum FolderRole: String, Codable, Sendable {
    case inbox, drafts, sent, trash, junk, archive
}

/// A folder by the name the server uses, and its role if known.
public struct MailFolder: Codable, Equatable, Sendable {
    /// The server's raw name, modified UTF-7 for anything outside ASCII ("Odeslan&AOk-" for "Odeslané"). Every call that takes a
    /// folder, and the account's folder settings, want this name unchanged.
    public let name: String
    public let role: FolderRole?

    public init(name: String, role: FolderRole?) {
        self.name = name
        self.role = role
    }
}

/// The one JSON style bots see: compact, sorted keys, ISO 8601 dates, unescaped slashes.
public enum MailJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
