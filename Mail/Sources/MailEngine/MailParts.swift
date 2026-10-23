import Foundation
import SwiftMail

/// One leaf part of a message, as the engine needs it.
struct PartRecord: Equatable, Sendable {
    let section: String
    /// Lowercase MIME type without parameters, e.g. "text/plain".
    let contentType: String
    let charset: String?
    /// Lowercase disposition without parameters, e.g. "attachment" or "inline".
    let disposition: String?
    /// The filename the sender gave, nil when there is none; a name SwiftMail made up from the Content-ID does not count.
    let filename: String?
    let size: Int?

    init(section: String, contentType: String, charset: String?, disposition: String?, filename: String?, size: Int?) {
        self.section = section
        self.contentType = contentType
        self.charset = charset
        self.disposition = disposition
        self.filename = filename
        self.size = size
    }
}

extension PartRecord {
    init(_ part: MessagePart) {
        let type = part.contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "application/octet-stream"
        let disposition = part.disposition?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        // On the IMAP path SwiftMail names a part that has no name after its Content-ID, angle brackets trimmed. The sender gave no such filename.
        var filename = part.filename
        if let contentId = part.contentId, filename == contentId.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) { filename = nil }
        self.init(section: part.section.description, contentType: type, charset: part.declaredCharset,
                  disposition: disposition, filename: filename, size: part.size)
    }
}

enum MailParts {
    /// The part shown as the message text: the first text/plain that isn't an attachment, else the first such text/html; nil when there is neither.
    static func body(in parts: [PartRecord]) -> PartRecord? {
        parts.first { !isAttachment($0) && $0.contentType == "text/plain" } ?? html(in: parts)
    }

    /// The first text/html part that isn't an attachment; also what a blank plain-text body gives way to.
    static func html(in parts: [PartRecord]) -> PartRecord? {
        parts.first { !isAttachment($0) && $0.contentType == "text/html" }
    }

    /// What a person calls attachments: parts marked "attachment", text/plain and text/html parts that have a filename, and every other
    /// part that isn't text/plain, text/html or a container (a text/calendar invite included), except the body. A text alternative
    /// without a filename (the HTML next to a plain-text body) is not an attachment. Names and types are cut like a header value,
    /// because a sender is as free to make them huge as a subject.
    static func attachments(in parts: [PartRecord], excluding body: PartRecord?) -> [AttachmentInfo] {
        parts.filter { $0 != body && isAttachment($0) }
            .map { AttachmentInfo(part: $0.section, name: MailText.capped($0.filename) ?? "part-\($0.section)",
                                  type: MailText.capped($0.contentType) ?? $0.contentType, size: $0.size) }
    }

    private static func isAttachment(_ part: PartRecord) -> Bool {
        if part.disposition == "attachment" { return true }
        if part.contentType.hasPrefix("multipart/") { return false }
        if part.contentType == "text/plain" || part.contentType == "text/html" { return part.filename != nil }
        return true
    }
}
