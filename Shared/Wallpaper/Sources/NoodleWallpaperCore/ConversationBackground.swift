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
    public var mediaKind: BackgroundMediaKind?
    public init(preset: ConversationBackgroundPreset? = nil, imageFilename: String? = nil, mediaKind: BackgroundMediaKind? = nil) {
        self.preset = preset
        self.imageFilename = imageFilename
        self.mediaKind = mediaKind
    }
    public var isDefault: Bool { preset == nil && imageFilename == nil }

    public static func canUseImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return isImageSource(source)
    }

    public static func isImageSource(_ source: CGImageSource) -> Bool {
        // ImageIO can create a source for arbitrary text without recognizing an image.
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}

public enum ConversationBackgroundError: LocalizedError {
    case invalidImage
    case invalidMedia
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "Choose a readable image smaller than 50 MB."
        case .invalidMedia: return "Choose a readable image or HEIC up to 512 MB, or a playable MP4, M4V or MOV video up to 1 GB. Wallpaper packages and streaming playlists are not supported."
        }
    }
}
