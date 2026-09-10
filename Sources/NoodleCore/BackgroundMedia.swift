import Foundation
@_exported import NoodleWallpaperCore

extension WorkspaceRepository {
    @discardableResult public func setBackground(conversationID: UUID, file: PreparedBackgroundFile) throws -> ConversationBackground {
        let background = ConversationBackground(imageFilename: "\(UUID().uuidString.lowercased()).\(file.url.pathExtension)", mediaKind: file.kind)
        guard FileManager.default.fileExists(atPath: conversationDirectory(id: conversationID).appendingPathComponent("conversation.json").path),
              let target = backgroundImageURL(background, conversationID: conversationID) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: file.url, to: target)
            return try persistBackground(background, conversationID: conversationID)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }
}
