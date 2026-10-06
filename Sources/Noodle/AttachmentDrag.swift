import AppKit
import NoodleCore
import UniformTypeIdentifiers

enum AttachmentDrag {
    static func provider(
        for attachment: ConversationAttachment,
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> NSItemProvider {
        let manager = FileManager.default
        let filename = try exportFilename(for: attachment, fileURL: fileURL)

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

    /// Copies the stored file to where the person chose in the save panel, which already confirmed any replacement.
    static func save(fileURL: URL, to destination: URL) throws {
        try requirePlainFile(fileURL)
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            let copy = try temporaryCopy(of: fileURL)
            defer { try? manager.removeItem(at: copy.deletingLastPathComponent()) }
            _ = try manager.replaceItemAt(destination, withItemAt: copy)
        } else {
            try manager.copyItem(at: fileURL, to: destination)
        }
    }

    private static func temporaryCopy(of fileURL: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleAttachmentSave-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(fileURL.lastPathComponent)
        try FileManager.default.copyItem(at: fileURL, to: copy)
        return copy
    }

    private static func requirePlainFile(_ fileURL: URL) throws {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard fileURL.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WorkspaceError.invalidAttachment
        }
    }

    /// The attachment's display name, once its stored file is known to be a plain file.
    private static func exportFilename(for attachment: ConversationAttachment, fileURL: URL) throws -> String {
        try requirePlainFile(fileURL)
        let filename = (attachment.originalFilename as NSString).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            throw WorkspaceError.invalidAttachment
        }
        return filename
    }
}

extension ConversationAttachment {
    /// Links, companions and annotations have no file of their own to save.
    var isSavable: Bool { url == nil && annotation == nil }
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

    func saveAttachment(_ attachment: ConversationAttachment) {
        let fileURL = attachmentFileURL(attachment)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (attachment.originalFilename as NSString).lastPathComponent
        let save = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try AttachmentDrag.save(fileURL: fileURL, to: destination)
            } catch {
                self?.errorMessage = "The attachment could not be saved: \(error.localizedDescription)"
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: save) }
        else { panel.begin(completionHandler: save) }
    }

    func saveTable(_ table: MessageTable) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Table.csv"
        let save = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try Data(table.csv.utf8).write(to: destination, options: .atomic)
            } catch {
                self?.errorMessage = "The table could not be saved: \(error.localizedDescription)"
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: save) }
        else { panel.begin(completionHandler: save) }
    }
}
