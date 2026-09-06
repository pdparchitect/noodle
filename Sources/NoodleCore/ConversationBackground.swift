import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ConversationBackgroundPreset: String, Codable, CaseIterable, Sendable {
    case sunset, ocean, forest, dusk
}

/// Local appearance only: kept out of message delivery and the agent workspace.
public struct ConversationBackground: Codable, Equatable, Sendable {
    public var preset: ConversationBackgroundPreset?
    public var imageFilename: String?
    public init(preset: ConversationBackgroundPreset? = nil, imageFilename: String? = nil) {
        self.preset = preset
        self.imageFilename = imageFilename
    }
    public var isDefault: Bool { preset == nil && imageFilename == nil }
}

public enum ConversationBackgroundError: LocalizedError {
    case invalidImage
    public var errorDescription: String? { "Choose a readable image smaller than 50 MB." }
}

extension WorkspaceRepository {
    public func loadBackground(conversationID: UUID) throws -> ConversationBackground {
        let url = conversationDirectory(id: conversationID).appendingPathComponent("background.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ConversationBackground() }
        return try JSONDecoder().decode(ConversationBackground.self, from: Data(contentsOf: url))
    }

    public func backgroundImageURL(_ background: ConversationBackground, conversationID: UUID) -> URL? {
        guard let name = background.imageFilename, name.hasSuffix(".jpg"),
              UUID(uuidString: String(name.dropLast(4))) != nil else { return nil }
        return conversationDirectory(id: conversationID).appendingPathComponent("Backgrounds", isDirectory: true)
            .appendingPathComponent(name)
    }

    @discardableResult public func setBackground(conversationID: UUID, preset: ConversationBackgroundPreset?) throws -> ConversationBackground {
        try persistBackground(ConversationBackground(preset: preset), conversationID: conversationID)
    }

    @discardableResult public func setBackground(conversationID: UUID, imageData: Data) throws -> ConversationBackground {
        guard imageData.count <= 50 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ConversationBackgroundError.invalidImage }
        let directory = conversationDirectory(id: conversationID)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversation.json").path) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let background = ConversationBackground(imageFilename: "\(UUID().uuidString.lowercased()).jpg")
        let url = backgroundImageURL(background, conversationID: conversationID)!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversationBackgroundError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversationBackgroundError.invalidImage }
        try (output as Data).write(to: url, options: .atomic)
        do { return try persistBackground(background, conversationID: conversationID) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    private func persistBackground(_ background: ConversationBackground, conversationID: UUID) throws -> ConversationBackground {
        let directory = conversationDirectory(id: conversationID)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversation.json").path) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let previous = try loadBackground(conversationID: conversationID)
        try JSONEncoder().encode(background).write(to: directory.appendingPathComponent("background.json"), options: .atomic)
        if let old = backgroundImageURL(previous, conversationID: conversationID), previous.imageFilename != background.imageFilename {
            try? FileManager.default.removeItem(at: old)
        }
        return background
    }
}
