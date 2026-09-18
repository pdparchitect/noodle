import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An Apple desktop picture whose image is already on disk. Most catalogue
/// entries are `.madesktop` descriptors; their image exists only after System
/// Settings has downloaded it, so undownloaded entries are never offered.
public struct SystemWallpaper: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let thumbnailURL: URL?

    public init(name: String, url: URL, thumbnailURL: URL?) {
        self.name = name
        self.url = url
        self.thumbnailURL = thumbnailURL
    }

    public static let catalogue = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)

    /// Sandboxed apps see a container as their home, so resolve the real one.
    /// Reading it needs a read-only sandbox exception for exactly this folder.
    public static var downloads: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/com.apple.mobileAssetDesktop", isDirectory: true)
    }

    public static func available(catalogue: URL = catalogue, downloads: URL = downloads) -> [SystemWallpaper] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: catalogue,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var seen = Set<String>()
        return entries.compactMap { entry -> SystemWallpaper? in
            let name = entry.deletingPathExtension().lastPathComponent
            let image: URL
            if entry.pathExtension.lowercased() == "madesktop" {
                guard let data = try? Data(contentsOf: entry),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let identifier = plist["mobileAssetID"] as? String,
                      !identifier.isEmpty, !identifier.hasPrefix("."), !identifier.contains("/") else { return nil }
                image = downloads.appendingPathComponent("\(identifier).heic")
            } else {
                image = entry
            }
            guard isUsableImage(image), seen.insert(image.standardizedFileURL.path).inserted else { return nil }
            let thumbnail = catalogue.appendingPathComponent(".thumbnails/\(name).heic")
            return SystemWallpaper(name: name, url: image,
                thumbnailURL: FileManager.default.isReadableFile(atPath: thumbnail.path) ? thumbnail : nil)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads only the header, so a partial or unreadable download is left out.
    private static func isUsableImage(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?,
              UTType(identifier)?.conforms(to: .image) == true else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
