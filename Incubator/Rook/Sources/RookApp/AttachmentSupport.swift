import AppKit
import NoodleCore
import RookCore
import SwiftUI
import UniformTypeIdentifiers

/// Noodle's attachment tiles show a noodlet link as a card; Rook has no noodlets, so such a link,
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
extension RookModel {
    func importPhoto(data: Data, into id: UUID) throws {
        if case .data(let data, let filename, let mediaType) = try AttachmentTransfer.photoPayload(data) {
            remember([], pending: try repository.importAttachment(data: data, originalFilename: filename, into: id, mediaType: mediaType))
        }
    }

    func importCapture(image: CGImage, title: String, region: AttachmentAnnotation.Region?, comment: String, into id: UUID) throws {
        let saved = try CaptureAttachment.save(image: image, title: title, region: region, comment: comment, into: id, repository: repository)
        remember([saved.source, saved.attachment].compactMap { $0 }, pending: saved.attachment)
    }

    /// An annotation on part of the conversation, with what it marks saved as its source.
    func saveConversationAnnotation(_ note: AttachmentAnnotation, content: Data, source: ConversationAttachment, sourceData: Data) throws {
        let saved = try ConversationAnnotationContent.save(note, content: content, source: source, sourceData: sourceData, repository: repository)
        remember([saved.source, saved.attachment], pending: saved.attachment)
    }

    func reviseAnnotationComment(_ attachment: ConversationAttachment, comment: String) throws -> ConversationAttachment {
        guard canEditAnnotation(attachment), let annotation = attachment.annotation else { throw WorkspaceError.invalidAttachment }
        let updated = try repository.reviseAnnotationComment(attachment, comment: comment,
            content: AnnotationContent.editedData(for: annotation.replacingComment(comment), originalURL: fileURL(attachment)))
        remember([updated], pending: updated)
        return updated
    }
}

extension RookModel {
    /// A drop on a sidebar row, as in Noodle: a file dragged out of another conversation is forwarded there, and
    /// anything else waits in that conversation's draft, which opens.
    func drop(_ providers: [NSItemProvider], onConversation id: UUID) -> Bool {
        // Only where a message could be sent, as in Noodle.
        guard !providers.isEmpty, let conversation = conversation(id), takesMessages(conversation) else { return false }
        Task {
            await AttachmentDrag.drop(providers, on: id, forward: { try self.forward($0, to: id, comment: "") },
                                      stage: { others in
                                          self.selection = id
                                          self.attachDropped(others, to: id)
                                      }, failed: { self.problem = $0 })
        }
        return true
    }

    /// Files dropped or pasted on the conversation itself, as in Noodle: they wait in its message field.
    func attachDropped(_ providers: [NSItemProvider], to id: UUID, context: AttachmentTransfer.Context = .drop) {
        markRead(id)
        Task {
            for provider in providers {
                do { attach([try await AttachmentTransfer.load(provider, context: context)], to: id) }
                catch { problem = error.localizedDescription }
            }
        }
    }
}

extension RookModel {
    /// Asks where to save the Mission's zip, then writes it there.
    func exportMission(_ mission: Mission) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = Self.archiveName(of: mission) + ".zip"
        let save = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let destination = panel.url, let self else { return }
            do { try self.exportArchive(of: mission, to: destination) }
            catch { self.problem = "\(mission.reference) could not be exported: \(error.localizedDescription)" }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: save) } else { panel.begin(completionHandler: save) }
    }
}
