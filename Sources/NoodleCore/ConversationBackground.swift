import Foundation
import ImageIO
import UniformTypeIdentifiers
@_exported import NoodleWallpaperCore

extension WorkspaceRepository {
    public func loadBackground(conversationID: UUID) throws -> ConversationBackground {
        let url = conversationDirectory(id: conversationID).appendingPathComponent("background.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ConversationBackground() }
        return try JSONDecoder().decode(ConversationBackground.self, from: Data(contentsOf: url))
    }

    public func backgroundImageURL(_ background: ConversationBackground, conversationID: UUID) -> URL? {
        guard let name = background.imageFilename,
              name == (name as NSString).lastPathComponent,
              ["jpg", "heic", "heif", "mov", "mp4", "m4v"].contains((name as NSString).pathExtension),
              UUID(uuidString: (name as NSString).deletingPathExtension) != nil else { return nil }
        return conversationDirectory(id: conversationID).appendingPathComponent("Backgrounds", isDirectory: true)
            .appendingPathComponent(name)
    }

    @discardableResult public func setBackground(conversationID: UUID, preset: ConversationBackgroundPreset?,
                                                 commit: () throws -> Void = {}) throws -> ConversationBackground {
        try persistBackground(ConversationBackground(preset: preset), conversationID: conversationID, commit: commit)
    }

    @discardableResult public func setBackground(conversationID: UUID, imageData: Data,
                                                 commit: () throws -> Void = {}) throws -> ConversationBackground {
        let output = try BackgroundMedia.jpegData(from: imageData)
        let directory = conversationDirectory(id: conversationID)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversation.json").path) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let background = ConversationBackground(imageFilename: "\(UUID().uuidString.lowercased()).jpg")
        let url = backgroundImageURL(background, conversationID: conversationID)!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: url, options: .atomic)
        do { return try persistBackground(background, conversationID: conversationID, commit: commit) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    @discardableResult public func setBackground(from attachment: ConversationAttachment) throws -> ConversationBackground {
        let url = attachmentFileURL(attachment)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= 50 * 1024 * 1024 else { throw ConversationBackgroundError.invalidImage }
        return try setBackground(conversationID: attachment.conversationID, imageData: Data(contentsOf: url))
    }

    /// Keep the previous media until the enclosing settings commit succeeds.
    /// If it throws, restore the exact previous metadata (including its absence).
    func persistBackground(_ background: ConversationBackground, conversationID: UUID,
                           commit: () throws -> Void = {}) throws -> ConversationBackground {
        let directory = conversationDirectory(id: conversationID)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversation.json").path) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let metadata = directory.appendingPathComponent("background.json")
        let previousData = FileManager.default.fileExists(atPath: metadata.path) ? try Data(contentsOf: metadata) : nil
        let previous = try previousData.map { try JSONDecoder().decode(ConversationBackground.self, from: $0) }
            ?? ConversationBackground()
        try JSONEncoder().encode(background).write(to: metadata, options: .atomic)
        do { try commit() }
        catch {
            if let previousData { try previousData.write(to: metadata, options: .atomic) }
            else { try FileManager.default.removeItem(at: metadata) }
            throw error
        }
        if let old = backgroundImageURL(previous, conversationID: conversationID), previous.imageFilename != background.imageFilename {
            try? FileManager.default.removeItem(at: old)
        }
        return background
    }
}
