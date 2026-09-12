import AppKit
import ImageIO
import NoodleCore
import UniformTypeIdentifiers

@MainActor enum CaptureAttachment {
    struct Saved {
        let attachment: ConversationAttachment
        let source: ConversationAttachment?
    }
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw WorkspaceError.invalidAttachment
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WorkspaceError.invalidAttachment }
        return data as Data
    }
    static func save(image: CGImage, title: String, region: AttachmentAnnotation.Region?, comment: String,
                     into conversationID: UUID, repository: WorkspaceRepository) throws -> Saved {
        let safeTitle = String(title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(100))
        let filename = "Capture — \(safeTitle.isEmpty ? "Screen" : safeTitle).png"
        let raw = try png(image)
        // Validate before persisting the original so invalid comments cannot leave orphan captures.
        let proposed = ConversationAttachment(conversationID: conversationID, originalFilename: filename,
            storedFilename: filename, mediaType: "image/png", byteCount: Int64(raw.count))
        if let region, !AttachmentAnnotation(source: proposed, comment: comment, region: region).isValid {
            throw WorkspaceError.invalidAttachment
        }
        let source = try repository.importAttachment(data: raw, originalFilename: filename, into: conversationID, mediaType: "image/png")
        guard let region else { return Saved(attachment: source, source: nil) }
        do {
            let note = AttachmentAnnotation(source: source, comment: comment, region: region)
            let marked = try AnnotationContent.data(for: note, snapshot: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            let attachment = try repository.importAttachment(data: marked, originalFilename: "Annotation — \(filename)",
                into: conversationID, mediaType: "image/png", annotation: note)
            return Saved(attachment: attachment, source: source)
        } catch {
            try? repository.removeAttachment(source)
            throw error
        }
    }
}
