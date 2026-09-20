import AppletBridge
import BrowserBridge
import ComputerBridge
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension WorkspaceRepository {
    public func importAttachment(
        from sourceURL: URL,
        into conversationID: UUID,
        mediaType: String,
        now: Date = Date(),
        voice: VoiceMessage? = nil
    ) throws -> ConversationAttachment {
        if let voice {
            guard sourceURL.isFileURL, mediaType.hasPrefix("audio/"), voice.isValid else {
                throw WorkspaceError.invalidAttachment
            }
        }
        if !sourceURL.isFileURL {
            return try importLinkAttachment(sourceURL, into: conversationID, now: now)
        }
        guard try loadConversations().contains(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw WorkspaceError.invalidAttachment }

        let attachmentID = UUID()
        let resolvedMediaType = detectedImageMediaType(at: sourceURL) ?? mediaType
        let attachment = ConversationAttachment(
            id: attachmentID,
            conversationID: conversationID,
            originalFilename: sourceURL.lastPathComponent,
            storedFilename: storedAttachmentName(id: attachmentID, originalFilename: sourceURL.lastPathComponent),
            mediaType: resolvedMediaType,
            byteCount: Int64(values.fileSize ?? 0),
            createdAt: now,
            voice: voice
        )
        let directory = attachmentsDirectory(conversationID: conversationID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceURL,
            to: directory.appendingPathComponent(attachment.storedFilename)
        )
        try write(attachment, to: directory.appendingPathComponent("\(attachment.id.uuidString.lowercased()).json"))
        return attachment
    }

    public func importAttachment(
        data: Data,
        originalFilename: String,
        into conversationID: UUID,
        mediaType: String,
        now: Date = Date(),
        linkURL: URL? = nil,
        computer: ComputerCard? = nil,
        browser: BrowserCard? = nil,
        annotation: AttachmentAnnotation? = nil
    ) throws -> ConversationAttachment {
        if let annotation {
            guard annotation.isValid, computer == nil, browser == nil, linkURL == nil, mediaType == annotation.mediaType,
                  let source = try loadAttachments(conversationID: conversationID).first(where: { $0.id == annotation.sourceAttachmentID }),
                  source.originalFilename == annotation.sourceFilename else { throw WorkspaceError.invalidAttachment }
            if let messageID = annotation.sourceMessageID {
                guard try loadMessages(conversationID: conversationID).contains(where: { $0.id == messageID }) else {
                    throw WorkspaceError.invalidAttachment
                }
            }
            if annotation.version == 1 {
                guard data.starts(with: Data("%PDF-".utf8)) else { throw WorkspaceError.invalidAttachment }
            } else if annotation.region != nil {
                guard detectedImageMediaType(in: data) == "image/png",
                      let image = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw WorkspaceError.invalidAttachment }
            } else {
                guard data == Data(annotation.textRepresentation.utf8) else { throw WorkspaceError.invalidAttachment }
            }
        }
        if let computer {
            guard computer.version == 1, mediaType == ComputerCard.mediaType, linkURL == nil, browser == nil,
                  data.count <= 900_000, (try? JSONDecoder().decode(ComputerReference.self, from: data)) == computer.reference else {
                throw WorkspaceError.invalidAttachment
            }
        }
        if let browser {
            guard computer == nil, annotation == nil, linkURL == nil, mediaType == BrowserReference.mediaType,
                  (try? BrowserReference.decode(data)) == browser.reference else { throw WorkspaceError.invalidAttachment }
        }
        if let linkURL {
            guard MessageLink.publicWebURL(from: linkURL, preservingFragment: true) == linkURL || NoodletLink.id(in: linkURL) != nil,
                  mediaType == "application/x-webloc",
                  let bookmark = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                  bookmark["URL"] == linkURL.absoluteString else { throw WorkspaceError.invalidAttachment }
        }
        guard try loadConversations().contains(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }

        let filename = URL(fileURLWithPath: originalFilename).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty else { throw WorkspaceError.invalidAttachment }

        let attachmentID = UUID()
        let resolvedMediaType = detectedImageMediaType(in: data) ?? mediaType
        let attachment = ConversationAttachment(
            id: attachmentID,
            conversationID: conversationID,
            originalFilename: filename,
            storedFilename: storedAttachmentName(id: attachmentID, originalFilename: filename),
            mediaType: resolvedMediaType,
            byteCount: Int64(data.count),
            createdAt: now,
            url: linkURL,
            computer: computer,
            browser: browser,
            annotation: annotation
        )
        let directory = attachmentsDirectory(conversationID: conversationID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(
            to: directory.appendingPathComponent(attachment.storedFilename),
            options: .atomic
        )
        do {
            try write(attachment, to: directory.appendingPathComponent("\(attachment.id.uuidString.lowercased()).json"))
        } catch {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(attachment.storedFilename))
            throw error
        }
        return attachment
    }

    public func importLinkAttachment(_ url: URL, into conversationID: UUID, now: Date = Date()) throws -> ConversationAttachment {
        guard let url = NoodletLink.canonical(url)
            ?? MessageLink.publicWebURL(from: url, preservingFragment: true) else { throw AttachmentSource.InvalidSource() }
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
        return try importAttachment(data: data, originalFilename: NoodletLink.id(in: url) != nil ? "Noodlet.webloc" : "\(url.host ?? "Link").webloc", into: conversationID,
            mediaType: "application/x-webloc", now: now, linkURL: url)
    }

    /// Only unsent annotations can change. Check message references under the
    /// same lock as submission, including edits from an already-open preview.
    public func reviseAnnotationComment(_ expected: ConversationAttachment, comment: String, content: Data) throws -> ConversationAttachment {
        try withConversationLock(expected.conversationID) {
            guard let current = try loadAttachments(conversationID: expected.conversationID).first(where: { $0.id == expected.id }),
                  let original = current.annotation, original == expected.annotation,
                  current.storedFilename == expected.storedFilename else { throw WorkspaceError.invalidAttachment }
            guard try !loadMessages(conversationID: current.conversationID)
                .contains(where: { $0.attachments.contains(current.id) }) else { throw WorkspaceError.invalidAttachment }
            let annotation = original.replacingComment(comment)
            guard annotation.isValid else { throw WorkspaceError.invalidAttachment }
            if annotation == original { return current }
            if annotation.version == 1 {
                guard content.starts(with: Data("%PDF-".utf8)) else { throw WorkspaceError.invalidAttachment }
            } else if annotation.region == nil {
                guard content == Data(annotation.textRepresentation.utf8) else { throw WorkspaceError.invalidAttachment }
            } else {
                guard content == (try Data(contentsOf: attachmentFileURL(current))) else { throw WorkspaceError.invalidAttachment }
            }
            let updated = ConversationAttachment(id: current.id,
                conversationID: current.conversationID, originalFilename: current.originalFilename,
                storedFilename: storedAttachmentName(id: UUID(), originalFilename: current.originalFilename),
                mediaType: current.mediaType, byteCount: Int64(content.count),
                createdAt: current.createdAt, annotation: annotation)
            let file = attachmentFileURL(updated)
            try content.write(to: file, options: .atomic)
            do {
                try write(updated, to: attachmentsDirectory(conversationID: current.conversationID)
                    .appendingPathComponent("\(updated.id.uuidString.lowercased()).json"))
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            try? FileManager.default.removeItem(at: attachmentFileURL(current))
            return updated
        }
    }

    public func loadAttachments(conversationID: UUID) throws -> [ConversationAttachment] {
        let directory = attachmentsDirectory(conversationID: conversationID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { metadataURL in
            let attachment = try read(ConversationAttachment.self, from: metadataURL)
            if attachment.url != nil { return attachment }
            let fileURL = attachmentFileURL(attachment)
            guard let detectedMediaType = detectedImageMediaType(at: fileURL),
                  detectedMediaType != attachment.mediaType else { return attachment }

            let repaired = ConversationAttachment(
                id: attachment.id,
                conversationID: attachment.conversationID,
                originalFilename: attachment.originalFilename,
                storedFilename: attachment.storedFilename,
                mediaType: detectedMediaType,
                byteCount: attachment.byteCount,
                createdAt: attachment.createdAt,
                voice: attachment.voice,
                computer: attachment.computer,
                browser: attachment.browser,
                annotation: attachment.annotation
            )
            try? write(repaired, to: metadataURL)
            return repaired
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    private func detectedImageMediaType(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return detectedImageMediaType(from: source)
    }

    private func detectedImageMediaType(in data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return detectedImageMediaType(from: source)
    }

    private func detectedImageMediaType(from source: CGImageSource) -> String? {
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let contentType = UTType(typeIdentifier),
              contentType.conforms(to: .image) else { return nil }
        return contentType.preferredMIMEType
    }

    public func attachmentFileURL(_ attachment: ConversationAttachment) -> URL {
        attachmentsDirectory(conversationID: attachment.conversationID)
            .appendingPathComponent(attachment.storedFilename)
    }

    public func removeAttachment(_ attachment: ConversationAttachment) throws {
        let file = attachmentFileURL(attachment)
        let metadata = attachmentsDirectory(conversationID: attachment.conversationID)
            .appendingPathComponent("\(attachment.id.uuidString.lowercased()).json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        if FileManager.default.fileExists(atPath: metadata.path) {
            try FileManager.default.removeItem(at: metadata)
        }
    }

    private func storedAttachmentName(id: UUID, originalFilename: String) -> String {
        let suffix = URL(fileURLWithPath: originalFilename).pathExtension
        return id.uuidString.lowercased() + (suffix.isEmpty ? "" : ".\(suffix)")
    }
}
