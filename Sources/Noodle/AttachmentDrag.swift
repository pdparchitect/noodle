import AppKit
import SwiftUI
import NoodleCore
import UniformTypeIdentifiers
import HubLink

enum AttachmentDrag {
    static func provider(
        for attachment: ConversationAttachment,
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> NSItemProvider {
        try exportedProvider(for: attachment, fileURL: fileURL, temporaryDirectory: temporaryDirectory).provider
    }

    /// The provider and the separate file it offers, which identifies the attachment when it is dropped back on Noodle.
    static func exportedProvider(
        for attachment: ConversationAttachment,
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> (provider: NSItemProvider, file: URL) {
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
        return (provider, exportedURL)
    }

    /// A file that is not on this Mac yet, offered under its name and fetched by `download` once it is dropped.
    static func promisedProvider(for attachment: ConversationAttachment,
                                 download: @escaping @MainActor @Sendable () async throws -> URL) -> NSItemProvider {
        let filename = (attachment.originalFilename as NSString).lastPathComponent
        let provider = NSItemProvider()
        provider.suggestedName = filename
        let contentType = UTType(mimeType: attachment.mediaType).flatMap { $0 == .data || $0.isDynamic ? nil : $0 }
            ?? UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: contentType.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    let file = try await download()
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleAttachmentDrag-\(UUID())", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let exported = directory.appendingPathComponent(filename.isEmpty ? file.lastPathComponent : filename)
                    try FileManager.default.copyItem(at: file, to: exported)
                    completion(exported, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    /// Files recently dragged out of a conversation, by the copy each drag offered, so a drop on another
    /// conversation can tell them from files dragged in from elsewhere. Only the latest drags are kept.
    @MainActor private static var dragged: [(file: URL, attachment: ConversationAttachment)] = []
    private static let draggedLimit = 32

    @MainActor static func remember(_ attachment: ConversationAttachment, exportedAs file: URL) {
        dragged.append((file.resolvingSymlinksInPath(), attachment))
        if dragged.count > draggedLimit { dragged.removeFirst(dragged.count - draggedLimit) }
    }

    /// The conversation file a dropped item was dragged from, if it came from one.
    @MainActor static func draggedAttachment(in provider: NSItemProvider) async -> ConversationAttachment? {
        guard !dragged.isEmpty, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: object as? URL)
            }
        }
        guard let file = url?.resolvingSymlinksInPath(), file.isFileURL else { return nil }
        return dragged.last { $0.file == file }?.attachment
    }

    /// The provider a drag out of a conversation offers: the file's own copy, remembered so a drop on another
    /// conversation can forward it, or nothing when it cannot be read.
    @MainActor static func dragProvider(for attachment: ConversationAttachment, fileURL: URL,
                                        failed: (String) -> Void) -> NSItemProvider {
        do {
            let export = try exportedProvider(for: attachment, fileURL: fileURL)
            remember(attachment, exportedAs: export.file)
            return export.provider
        } catch {
            failed("The attachment could not be dragged: \(error.localizedDescription)")
            return NSItemProvider()
        }
    }

    /// A link as its address; a picture as itself, so it pastes as one, along with its file; anything else as
    /// its file. False when nothing could be written.
    @MainActor @discardableResult
    static func copy(_ attachment: ConversationAttachment, fileURL url: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        if let link = attachment.url {
            pasteboard.setString(link.absoluteString, forType: .string)
            pasteboard.setString(link.absoluteString, forType: .URL)
            return true
        }
        if attachment.mediaType.hasPrefix("image/"),
           let image = NSImage(contentsOf: url),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setData(pngData, forType: .png)
            item.setData(tiffData, forType: .tiff)
            if pasteboard.writeObjects([item]) { return true }
            pasteboard.clearContents()
        }
        return pasteboard.writeObjects([url as NSURL])
    }

    /// Save…: asks where, on the key window, then keeps a copy there.
    @MainActor static func presentSavePanel(for attachment: ConversationAttachment, fileURL: URL,
                                            failed: @escaping @MainActor (String) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (attachment.originalFilename as NSString).lastPathComponent
        let save = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try AttachmentDrag.save(fileURL: fileURL, to: destination)
            } catch {
                failed("The attachment could not be saved: \(error.localizedDescription)")
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: save) }
        else { panel.begin(completionHandler: save) }
    }

    /// A drop on a conversation in the sidebar: a file dragged out of another conversation is forwarded there,
    /// as Forward… sends it with no comment; anything else is given to `stage`, to wait in that conversation.
    @MainActor static func drop(_ providers: [NSItemProvider], on conversationID: UUID,
                                forward: (ConversationAttachment) async throws -> Void,
                                stage: ([NSItemProvider]) -> Void, failed: (String) -> Void) async {
        var others: [NSItemProvider] = []
        for provider in providers {
            guard let attachment = await draggedAttachment(in: provider) else {
                others.append(provider)
                continue
            }
            // Back on its own conversation, it is already there.
            guard attachment.conversationID != conversationID else { continue }
            guard attachment.isForwardable else {
                others.append(provider)
                continue
            }
            do {
                try await forward(attachment)
            } catch {
                failed("The attachment could not be sent: \(error.localizedDescription)")
            }
        }
        if !others.isEmpty { stage(others) }
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

/// A sidebar row that takes a dropped file for its conversation, and shows where it will land.
private struct ConversationDropTarget: ViewModifier {
    let drop: ([NSItemProvider]) -> Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.25))
                        .padding(.horizontal, -6)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(of: AttachmentTransfer.dropContentTypes, isTargeted: $isTargeted, perform: drop)
    }
}

extension View {
    func conversationDropTarget(_ drop: @escaping ([NSItemProvider]) -> Bool) -> some View {
        modifier(ConversationDropTarget(drop: drop))
    }
}
