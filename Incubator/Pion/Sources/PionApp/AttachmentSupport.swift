import NoodleCore
import SwiftUI

/// Noodle's attachment tiles show a noodlet link as a card; Pion has no noodlets, so such a link,
/// which only an agent could have written, shows as a plain card naming it.
struct NoodletAttachmentCard: View {
    let url: URL
    let shouldLoad: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "square.grid.2x2").font(.system(size: 30)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(url.lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(12)
    }
}

// The same attachments as Noodle's: photos, captures, annotations on a file, a link or the conversation
// itself, each saved by the shared repository into the draft of the conversation it came from.
extension PionModel {
    func fileURL(_ attachment: ConversationAttachment) -> URL { repository.attachmentFileURL(attachment) }

    func importPhoto(data: Data, into id: UUID) {
        do {
            if case .data(let data, let filename, let mediaType) = try AttachmentTransfer.photoPayload(data) {
                remember([], pending: try repository.importAttachment(data: data, originalFilename: filename, into: id, mediaType: mediaType))
            }
        } catch { problem = error.localizedDescription }
    }

    func importCapture(image: CGImage, title: String, region: AttachmentAnnotation.Region?, comment: String, into id: UUID) throws {
        let saved = try CaptureAttachment.save(image: image, title: title, region: region, comment: comment, into: id, repository: repository)
        remember([saved.source, saved.attachment].compactMap { $0 }, pending: saved.attachment)
    }

    /// An annotation on a file, saved beside it as a new attachment for the next message.
    func saveAnnotation(_ annotation: AttachmentAnnotation, content: Data, source: ConversationAttachment) throws {
        let stem = URL(fileURLWithPath: source.originalFilename).deletingPathExtension().lastPathComponent
        let attachment = try repository.importAttachment(data: content,
            originalFilename: "Annotation — \(stem.prefix(160)).\(annotation.fileExtension)", into: source.conversationID,
            mediaType: annotation.mediaType, annotation: annotation)
        remember([attachment], pending: attachment)
    }

    /// An annotation on part of the conversation, with what it marks saved as its source.
    func saveConversationAnnotation(_ note: AttachmentAnnotation, content: Data, source: ConversationAttachment, sourceData: Data) throws {
        let saved = try ConversationAnnotationContent.save(note, content: content, source: source, sourceData: sourceData, repository: repository)
        remember([saved.source, saved.attachment], pending: saved.attachment)
    }

    /// An annotation can be changed until a message carries it.
    func canEditAnnotation(_ attachment: ConversationAttachment) -> Bool {
        attachment.annotation != nil && (pendingAttachments[attachment.conversationID] ?? []).contains { $0.id == attachment.id }
            && !messages(in: attachment.conversationID).contains { $0.attachments.contains(attachment.id) }
    }

    func reviseAnnotationComment(_ attachment: ConversationAttachment, comment: String) throws -> ConversationAttachment {
        guard canEditAnnotation(attachment), let annotation = attachment.annotation else { throw WorkspaceError.invalidAttachment }
        let updated = try repository.reviseAnnotationComment(attachment, comment: comment,
            content: AnnotationContent.editedData(for: annotation.replacingComment(comment), originalURL: fileURL(attachment)))
        remember([updated], pending: updated)
        return updated
    }

    /// The files a message carries, in its order.
    func files(of message: ChatMessage) -> [ConversationAttachment] {
        message.attachments.compactMap { attachment($0, in: message.conversationID) }
    }
}
