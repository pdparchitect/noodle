import Foundation
import NoodleCore

enum ConversationAnnotationContent {
    struct Saved {
        let source: ConversationAttachment
        let attachment: ConversationAttachment
    }

    /// Persist the immutable source only on Save. Rebind the annotation to the
    /// repository's source ID, and roll it back if creating the note fails.
    static func save(_ note: AttachmentAnnotation, content: Data, source: ConversationAttachment,
                     sourceData: Data, repository: WorkspaceRepository) throws -> Saved {
        guard note.isValid, note.sourceAttachmentID == source.id,
              note.sourceFilename == source.originalFilename else { throw WorkspaceError.invalidAttachment }
        let savedSource = try repository.importAttachment(data: sourceData, originalFilename: source.originalFilename,
            into: source.conversationID, mediaType: source.mediaType)
        do {
            let savedNote = AttachmentAnnotation(source: savedSource, quote: note.quote, comment: note.comment,
                region: note.region, sourceMessageID: note.sourceMessageID)
            let data = savedNote.region == nil ? Data(savedNote.textRepresentation.utf8) : content
            let stem = URL(fileURLWithPath: source.originalFilename).deletingPathExtension().lastPathComponent
            let attachment = try repository.importAttachment(data: data,
                originalFilename: "Annotation — \(stem.prefix(160)).\(savedNote.fileExtension)",
                into: source.conversationID, mediaType: savedNote.mediaType, annotation: savedNote)
            return Saved(source: savedSource, attachment: attachment)
        } catch {
            try? repository.removeAttachment(savedSource)
            throw error
        }
    }
}
