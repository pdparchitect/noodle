import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An Apple wallpaper whose image or video is already on disk. Most catalogue
/// entries are `.madesktop` descriptors; their image exists only after System
/// Settings has downloaded it, so undownloaded entries are never offered.
/// Aerials are videos that System Settings keeps in a folder of their own.
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
    /// Reading each folder needs a read-only sandbox exception for exactly that folder.
    private static func applicationSupport(_ folder: String) -> URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/\(folder)", isDirectory: true)
    }

    public static var downloads: URL { applicationSupport("com.apple.mobileAssetDesktop") }
    public static var aerials: URL { applicationSupport("com.apple.wallpaper/aerials") }

    public static func available(catalogue: URL = catalogue, downloads: URL = downloads,
                                 aerials: URL = aerials) -> [SystemWallpaper] {
        (stills(catalogue: catalogue, downloads: downloads) + aerialVideos(in: aerials))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func stills(catalogue: URL, downloads: URL) -> [SystemWallpaper] {
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
    }

    /// Each downloaded aerial is `videos/<asset id>.mov`, with its preview in
    /// `thumbnails` and its display name in the manifest beside them.
    private static func aerialVideos(in aerials: URL) -> [SystemWallpaper] {
        let videos = (try? FileManager.default.contentsOfDirectory(at: aerials.appendingPathComponent("videos"),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        guard !videos.isEmpty else { return [] }
        struct Manifest: Decodable {
            struct Asset: Decodable { let id: String; let accessibilityLabel: String? }
            let assets: [Asset]
        }
        let manifest = (try? Data(contentsOf: aerials.appendingPathComponent("manifest/entries.json")))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        let names = Dictionary((manifest?.assets ?? []).compactMap { asset in asset.accessibilityLabel.map { (asset.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        return videos.compactMap { video -> SystemWallpaper? in
            guard UTType(filenameExtension: video.pathExtension)?.conforms(to: .movie) == true,
                  let values = try? video.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
            let identifier = video.deletingPathExtension().lastPathComponent
            let thumbnail = aerials.appendingPathComponent("thumbnails/\(identifier).png")
            return SystemWallpaper(name: names[identifier] ?? "Aerial", url: video,
                thumbnailURL: FileManager.default.isReadableFile(atPath: thumbnail.path) ? thumbnail : nil)
        }
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
