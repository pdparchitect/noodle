import Foundation
import NoodleCore
import UniformTypeIdentifiers

enum AttachmentDrag {
    static func provider(
        for attachment: ConversationAttachment,
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> NSItemProvider {
        let manager = FileManager.default
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard fileURL.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WorkspaceError.invalidAttachment
        }

        let filename = (attachment.originalFilename as NSString).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            throw WorkspaceError.invalidAttachment
        }

        // Export a separate file with its display name. A destination may move
        // or edit a dropped file; it must never change conversation storage.
        // Keep it in system-managed temporary storage after the drag ends so
        // destinations that consume the file asynchronously can still read it.
        let directory = temporaryDirectory.appendingPathComponent("NoodleAttachmentDrag-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let exportedURL = directory.appendingPathComponent(filename)
        do {
            try manager.copyItem(at: fileURL, to: exportedURL)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }

        let provider = NSItemProvider()
        provider.suggestedName = filename
        let mediaType = UTType(mimeType: attachment.mediaType)
        let contentType = mediaType.flatMap { $0 == .data || $0.isDynamic ? nil : $0 }
            ?? UTType(filenameExtension: exportedURL.pathExtension)
            ?? .data
        // Offer the original bytes to image/document consumers and a file URL
        // to Finder, upload fields, and Noodle's own attachment importer.
        provider.registerFileRepresentation(forTypeIdentifier: contentType.identifier,
            fileOptions: [], visibility: .all) { completion in
            completion(exportedURL, false, nil)
            return nil
        }
        provider.registerObject(exportedURL as NSURL, visibility: .all)
        return provider
    }
}

extension NoodleStore {
    func attachmentDragProvider(_ attachment: ConversationAttachment) -> NSItemProvider {
        do {
            return try AttachmentDrag.provider(for: attachment, fileURL: attachmentFileURL(attachment))
        } catch {
            errorMessage = "The attachment could not be dragged: \(error.localizedDescription)"
            return NSItemProvider()
        }
    }
}
