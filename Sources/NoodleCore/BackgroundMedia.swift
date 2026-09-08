import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum BackgroundMediaKind: String, Codable, Sendable {
    case image, video, dynamicImage
}

/// Owns an immutable temporary copy, so previews and Apply never depend on an
/// expired picker permission or a subsequently moved original file.
public final class PreparedBackgroundFile: @unchecked Sendable {
    public let url: URL
    public let kind: BackgroundMediaKind
    private let directory: URL
    private init(url: URL, kind: BackgroundMediaKind, directory: URL) {
        self.url = url; self.kind = kind; self.directory = directory
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    public static func prepare(_ sourceURL: URL) async throws -> PreparedBackgroundFile {
        guard sourceURL.isFileURL else { throw ConversationBackgroundError.invalidMedia }
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1_073_741_824 else {
            throw ConversationBackgroundError.invalidMedia
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-background-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            // Inspect the private copy, not a mutable external file.
            let copy = directory.appendingPathComponent("source.\(sourceURL.pathExtension.lowercased())")
            try FileManager.default.copyItem(at: sourceURL, to: copy)
            let copied = try copy.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard copied.isRegularFile == true, copied.isSymbolicLink != true,
                  let copiedSize = copied.fileSize, copiedSize > 0, copiedSize <= 1_073_741_824 else {
                throw ConversationBackgroundError.invalidMedia
            }
            try Task.checkCancellation()
            if let source = CGImageSourceCreateWithURL(copy as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let identifier = CGImageSourceGetType(source) as String?, UTType(identifier)?.conforms(to: .image) == true {
                guard copiedSize <= 536_870_912, let first = BackgroundMedia.image(at: copy, index: 0) else {
                    throw ConversationBackgroundError.invalidMedia
                }
                let count = CGImageSourceGetCount(source)
                let heic = identifier == UTType.heic.identifier || identifier == UTType.heif.identifier
                if heic && count > 1 {
                    guard count <= 120 else { throw ConversationBackgroundError.invalidMedia }
                    let target = directory.appendingPathComponent("wallpaper.heic")
                    try FileManager.default.moveItem(at: copy, to: target)
                    return PreparedBackgroundFile(url: target, kind: .dynamicImage, directory: directory)
                }
                let target = directory.appendingPathComponent("wallpaper.jpg")
                guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw ConversationBackgroundError.invalidMedia
                }
                CGImageDestinationAddImage(destination, first, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ConversationBackgroundError.invalidMedia }
                try FileManager.default.removeItem(at: copy)
                return PreparedBackgroundFile(url: target, kind: .image, directory: directory)
            }
            guard ["mp4", "m4v", "mov"].contains(copy.pathExtension) else { throw ConversationBackgroundError.invalidMedia }
            let asset = BackgroundMedia.videoAsset(at: copy)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let playable = try await asset.load(.isPlayable)
                    let duration = try await asset.load(.duration).seconds
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    guard playable, duration.isFinite, duration > 0, !tracks.isEmpty else {
                        throw ConversationBackgroundError.invalidMedia
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(12))
                    asset.cancelLoading()
                    throw ConversationBackgroundError.invalidMedia
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            try Task.checkCancellation()
            return PreparedBackgroundFile(url: copy, kind: .video, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

public enum BackgroundMedia {
    public static func videoAsset(at url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    }

    public static func image(at url: URL, index: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              index >= 0, index < CGImageSourceGetCount(source) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    public static func frameCount(at url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return 0 }
        return min(120, CGImageSourceGetCount(source))
    }

    public static func poster(at url: URL, kind: BackgroundMediaKind?) async -> CGImage? {
        if kind != .video { return image(at: url, index: 0) }
        let generator = AVAssetImageGenerator(asset: videoAsset(at: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2560, height: 2560)
        return try? await generator.image(at: .zero).image
    }
}

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
