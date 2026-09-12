import Foundation

/// Feedback on a conversation attachment. Version 2 stores text as UTF-8 and
/// visual context as a marked PNG; the comment and source remain in metadata.
public struct AttachmentAnnotation: Codable, Hashable, Sendable {
    public struct Region: Codable, Hashable, Sendable {
        /// Fractions of the captured preview image, with a bottom-left origin.
        /// These are not PDF page coordinates or original-image pixel coordinates.
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        public var isValid: Bool {
            [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 &&
                width > 0 && height > 0 && x + width <= 1.000001 && y + height <= 1.000001
        }
    }

    public let version: Int
    public let sourceAttachmentID: UUID
    public let sourceFilename: String
    /// Original conversation message, when the source is a transcript excerpt.
    public let sourceMessageID: UUID?
    public let quote: String?
    public private(set) var comment: String
    public let region: Region?

    public init(source: ConversationAttachment, quote: String? = nil, comment: String, region: Region? = nil,
                version: Int = 2, sourceMessageID: UUID? = nil) {
        self.version = version
        sourceAttachmentID = source.id
        sourceFilename = source.originalFilename
        self.sourceMessageID = sourceMessageID
        self.quote = quote
        self.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region
    }

    public var isValid: Bool {
        (version == 1 || version == 2) && !sourceFilename.isEmpty && !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (region?.isValid ?? true) && !(quote != nil && region != nil)
    }

    public var mediaType: String {
        version == 1 ? "application/pdf" : region == nil ? "text/plain" : "image/png"
    }

    public var fileExtension: String {
        version == 1 ? "pdf" : region == nil ? "txt" : "png"
    }

    public func replacingComment(_ comment: String) -> Self {
        var copy = self
        copy.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    /// A readable companion file for text-only notes; metadata is authoritative
    /// for the boundaries between feedback and quoted source content.
    public var textRepresentation: String {
        let context = quote.map { "Selected text\n\($0)" } ?? (region == nil
            ? "This comment refers to the whole attachment." : "The marked preview snapshot follows on the next page.")
        let messageReference = sourceMessageID.map { "Source message: \($0.uuidString)\n" } ?? ""
        return "Annotation — \(sourceFilename)\n\nComment\n\(comment)\n\n\(context)\n\nSource attachment: \(sourceAttachmentID.uuidString)\n\(messageReference)"
    }
}

extension ConversationDrafts {
    public func canEditAnnotation(_ attachment: ConversationAttachment, messages: [ChatMessage]) -> Bool {
        attachment.annotation != nil &&
            self[attachment.conversationID].attachments.contains(where: { $0.id == attachment.id }) &&
            !messages.contains(where: { $0.attachments.contains(attachment.id) })
    }

    /// Annotation files are durable drafts until a message references them.
    /// Recover only annotations; ordinary composer state retains its existing policy.
    public mutating func restoreAnnotations(_ attachments: [ConversationAttachment], messages: [ChatMessage],
                                           conversationID: UUID) {
        let sent = Set(messages.flatMap(\.attachments))
        let saved = attachments.filter { $0.conversationID == conversationID && $0.annotation != nil && !sent.contains($0.id) }
        let existing = Set(self[conversationID].attachments.map(\.id))
        self[conversationID].attachments.append(contentsOf: saved.filter { !existing.contains($0.id) })
    }
}
