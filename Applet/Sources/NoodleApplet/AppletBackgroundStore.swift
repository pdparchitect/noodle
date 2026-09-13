import Combine
import Foundation
import NoodleWallpaperCore

/// One local wallpaper for the whole library, independent of individual noodlets.
@MainActor final class AppletBackgroundStore: ObservableObject {
    @Published private(set) var background: ConversationBackground
    private let root: URL

    init(root: URL) {
        self.root = root
        if let data = try? Data(contentsOf: root.appendingPathComponent("Background.json")),
           let saved = try? JSONDecoder().decode(ConversationBackground.self, from: data),
           saved.imageFilename == nil || Self.mediaURL(for: saved, root: root) != nil {
            background = saved
        } else {
            background = ConversationBackground()
        }
    }

    var imageURL: URL? { Self.mediaURL(for: background, root: root) }

    func apply(_ selection: ConversationBackground, file: PreparedBackgroundFile? = nil) async throws {
        let root = root
        let previous = background
        let saved = try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            var saved = selection
            var imported: URL?
            do {
                if let file {
                    let folder = root.appendingPathComponent("Backgrounds", isDirectory: true)
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = "\(UUID()).\(file.url.pathExtension)"
                    let target = folder.appendingPathComponent(name)
                    imported = target
                    try manager.copyItem(at: file.url, to: target)
                    saved = ConversationBackground(imageFilename: name, mediaKind: file.kind)
                } else if selection.imageFilename != nil {
                    guard selection == previous, Self.mediaURL(for: selection, root: root) != nil else {
                        throw ConversationBackgroundError.invalidMedia
                    }
                } else {
                    saved = ConversationBackground(preset: selection.preset)
                }
                try JSONEncoder().encode(saved).write(
                    to: root.appendingPathComponent("Background.json"), options: .atomic)
            } catch {
                if let imported { try? manager.removeItem(at: imported) }
                throw error
            }
            // Retire the old media only after the replacement and metadata are durable.
            if previous.imageFilename != saved.imageFilename,
               let old = Self.mediaURL(for: previous, root: root) {
                try? manager.removeItem(at: old)
            }
            return saved
        }.value
        background = saved
    }

    nonisolated private static func mediaURL(for background: ConversationBackground, root: URL) -> URL? {
        guard let name = background.imageFilename, !name.isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { return nil }
        let url = root.appendingPathComponent("Backgrounds", isDirectory: true).appendingPathComponent(name)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url
    }
}
