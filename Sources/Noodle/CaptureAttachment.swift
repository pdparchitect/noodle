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
    /// A window title made safe to name a file with.
    static func filenameTitle(_ title: String) -> String {
        String(title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(100))
    }
    static func save(image: CGImage, title: String, region: AttachmentAnnotation.Region?, comment: String, quote: String? = nil,
                     into conversationID: UUID, repository: WorkspaceRepository) throws -> Saved {
        let safeTitle = filenameTitle(title)
        let filename = "Capture — \(safeTitle.isEmpty ? "Screen" : safeTitle).png"
        let raw = try png(image)
        // Validate before persisting the original so invalid comments cannot leave orphan captures.
        let proposed = ConversationAttachment(conversationID: conversationID, originalFilename: filename,
            storedFilename: filename, mediaType: "image/png", byteCount: Int64(raw.count))
        if let region, !AttachmentAnnotation(source: proposed, quote: quote, comment: comment, region: region).isValid {
            throw WorkspaceError.invalidAttachment
        }
        let source = try repository.importAttachment(data: raw, originalFilename: filename, into: conversationID, mediaType: "image/png")
        guard let region else { return Saved(attachment: source, source: nil) }
        do {
            let note = AttachmentAnnotation(source: source, quote: quote, comment: comment, region: region)
            let marked = try AnnotationContent.data(for: note, snapshot: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            let attachment = try repository.importAnnotation(note, content: marked, on: source)
            return Saved(attachment: attachment, source: source)
        } catch {
            try? repository.removeAttachment(source)
            throw error
        }
    }
}
