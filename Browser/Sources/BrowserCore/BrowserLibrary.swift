import BrowserBridge
import AppKit
import Combine
import Foundation
import ImageIO
@_exported import NoodleWallpaperCore

public struct BrowserProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var colour: Int
    public var iconImage: Data?
    public var muted: Bool
    public var paused: Bool
    public var tabs: [BrowserTabInfo]
    public var selectedTabID: UUID?
    public var downloads: [BrowserDownloadInfo]
    public var backgroundPreset: String?
    public var backgroundFilename: String?
    public var backgroundMediaKind: BackgroundMediaKind?
    public var background: ConversationBackground {
        get { .init(preset: backgroundPreset.flatMap(ConversationBackgroundPreset.init(rawValue:)), imageFilename: backgroundFilename, mediaKind: backgroundMediaKind) }
        set { backgroundPreset = newValue.preset?.rawValue; backgroundFilename = newValue.imageFilename; backgroundMediaKind = newValue.mediaKind }
    }
    public init(id: UUID = UUID(), name: String, colour: Int = 0) {
        self.id = id; self.name = name; self.colour = colour; symbol = "globe"
        muted = true; paused = false; tabs = []; downloads = []
    }
    public var remote: RemoteBrowser { .init(id: id, name: name, symbol: symbol, colour: colour, icon: catalogueIcon, muted: muted, paused: paused, tabCount: tabs.count) }
    private var catalogueIcon: Data? {
        guard let iconImage, let source = CGImageSourceCreateWithData(iconImage as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              data.count <= 65_536 else { return nil }
        return data
    }
}

@MainActor public final class BrowserLibrary: ObservableObject {
    private struct Archive: Codable { var version = 1; var profiles: [BrowserProfile] }
    @Published public private(set) var profiles: [BrowserProfile] = []
    @Published public private(set) var failure: String?
    @Published public private(set) var recordsRevision = 0
    private var recordStores: [UUID: BrowserRecords] = [:]
    public let root: URL
    private var readable = true
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NoodleBrowser", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let archiveURL = self.root.appendingPathComponent("browsers.json")
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                let data = try Data(contentsOf: archiveURL)
                guard data.count <= 16 * 1_048_576 else { throw BrowserError("Browser library is too large.") }
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                guard archive.version == 1, archive.profiles.count <= 1000,
                      Set(archive.profiles.map(\.id)).count == archive.profiles.count else { throw BrowserError("Unsupported or invalid browser library.") }
                profiles = archive.profiles
                for index in profiles.indices {
                    guard Set(profiles[index].tabs.map(\.id)).count == profiles[index].tabs.count,
                          Set(profiles[index].downloads.map(\.id)).count == profiles[index].downloads.count else { throw BrowserError("Invalid browser records.") }
                    for d in profiles[index].downloads.indices where profiles[index].downloads[d].state == "downloading" {
                        profiles[index].downloads[d].state = "interrupted"
                        profiles[index].downloads[d].error = "Browser stopped before this download completed."
                    }
                    for t in profiles[index].tabs.indices { profiles[index].tabs[t].loading = false }
                }
            }
        } catch { readable = false; failure = "Could not read the browser library. Existing data was not changed. \(error.localizedDescription)" }
    }
    public func profile(_ id: UUID) throws -> BrowserProfile {
        guard readable, let result = profiles.first(where: { $0.id == id }) else { throw BrowserError(failure ?? "This browser no longer exists.") }
        return result
    }
    public var nextBrowserName: String {
        let names = Set(profiles.map { $0.name.lowercased() })
        if !names.contains("browser") { return "Browser" }
        var index = 2
        while names.contains("browser \(index)") { index += 1 }
        return "Browser \(index)"
    }
    @discardableResult public func create(name: String, symbol: String = "globe", colour: Int? = nil, iconImage: Data? = nil,
        background: ConversationBackground = .init(), backgroundFile: PreparedBackgroundFile? = nil) throws -> BrowserProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, profiles.count < 1000 else { throw BrowserError("Enter a browser name of 1–120 characters.") }
        var profile = BrowserProfile(name: name, colour: colour ?? profiles.count % 6)
        profile.symbol = symbol; profile.iconImage = iconImage; profile.background = background
        return try save(profile, new: true, backgroundFile: backgroundFile)
    }
    public func update(_ profile: BrowserProfile, backgroundFile: PreparedBackgroundFile? = nil) throws {
        _ = try save(profile, new: false, backgroundFile: backgroundFile)
    }
    private func save(_ profile: BrowserProfile, new: Bool, backgroundFile: PreparedBackgroundFile?) throws -> BrowserProfile {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, profile.name.count <= 120 else { throw BrowserError("Enter a browser name of 1–120 characters.") }
        guard (profile.iconImage?.count ?? 0) <= 2 * 1024 * 1024 else { throw BrowserError("The browser icon is too large.") }
        let previous = profiles.first { $0.id == profile.id }
        guard new ? previous == nil : previous != nil else { throw BrowserError("This browser no longer exists.") }
        var profile = profile
        var imported: URL?
        do {
            if let file = backgroundFile {
                let name = UUID().uuidString.lowercased() + "." + file.url.pathExtension
                guard Self.validBackgroundFilename(name) else { throw BrowserError("Invalid browser background file.") }
                let folder = root.appendingPathComponent(profile.id.uuidString.lowercased()).appendingPathComponent("Backgrounds")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let target = folder.appendingPathComponent(name)
                imported = target
                try FileManager.default.copyItem(at: file.url, to: target)
                profile.background = .init(imageFilename: name, mediaKind: file.kind)
            }
            guard profile.backgroundPreset.map({ ConversationBackgroundPreset(rawValue: $0) != nil }) ?? true,
                  profile.backgroundFilename.map(Self.validBackgroundFilename) ?? true,
                  (profile.backgroundFilename == nil) == (profile.backgroundMediaKind == nil) else {
                throw BrowserError("Invalid browser background.")
            }
            var next = profiles
            if new { next.append(profile) }
            else if let index = next.firstIndex(where: { $0.id == profile.id }) { next[index] = profile }
            try commit(next)
            if let previous, previous.backgroundFilename != profile.backgroundFilename, let old = backgroundURL(for: previous) {
                try? FileManager.default.removeItem(at: old)
            }
            return profile
        } catch {
            if let imported { try? FileManager.default.removeItem(at: imported) }
            throw error
        }
    }
    public func backgroundURL(for profile: BrowserProfile) -> URL? {
        guard let name = profile.backgroundFilename, Self.validBackgroundFilename(name) else { return nil }
        return root.appendingPathComponent(profile.id.uuidString.lowercased()).appendingPathComponent("Backgrounds").appendingPathComponent(name)
    }
    private static func validBackgroundFilename(_ name: String) -> Bool {
        name == (name as NSString).lastPathComponent && UUID(uuidString: (name as NSString).deletingPathExtension) != nil &&
            ["jpg", "heic", "heif", "mp4", "m4v", "mov"].contains((name as NSString).pathExtension)
    }
    public func remove(_ id: UUID) throws {
        _ = try profile(id)
        try commit(profiles.filter { $0.id != id })
        recordStores.removeValue(forKey: id)
    }
    private func records(_ id: UUID) throws -> BrowserRecords {
        _ = try profile(id)
        if let store = recordStores[id] { return store }
        let folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try BrowserRecords(url: folder.appendingPathComponent("records.sqlite"))
        recordStores[id] = store
        return store
    }
    public func history(_ id: UUID, query: String = "", limit: Int = 50, offset: Int = 0) throws -> (entries: [BrowserHistoryEntry], total: Int) {
        var request = BrowserRequest(.history, browserID: id); request.query = query; request.limit = limit; request.offset = offset; try request.validate()
        return try records(id).history(query: query, limit: limit, offset: offset)
    }
    @discardableResult public func recordVisit(_ id: UUID, url: String, title: String) throws -> UUID? {
        _ = try profile(id)
        // Internal pages, downloads and URLs containing credentials are not history.
        guard (try? BrowserRequest.navigationURL(url)) != nil else { return nil }
        let visit = try records(id).record(url: url, title: title)
        recordsRevision &+= 1
        return visit
    }
    public func updateHistoryTitle(_ id: UUID, visit: UUID, title: String) throws {
        try records(id).updateHistoryTitle(visit, title: title); recordsRevision &+= 1
    }
    public func clearHistory(_ id: UUID) throws {
        try records(id).clearHistory(); recordsRevision &+= 1
    }
    public func bookmarks(_ id: UUID, query: String = "", limit: Int = 50, offset: Int = 0) throws -> (entries: [BrowserBookmark], total: Int) {
        var request = BrowserRequest(.bookmarks, browserID: id); request.query = query; request.limit = limit; request.offset = offset; try request.validate()
        return try records(id).bookmarks(query: query, limit: limit, offset: offset)
    }
    @discardableResult public func addBookmark(_ id: UUID, url: String, title: String? = nil) throws -> BrowserBookmark {
        var request = BrowserRequest(.bookmarkAdd, browserID: id); request.url = url; request.title = title; try request.validate()
        let record = try records(id).addBookmark(url: url, title: title); recordsRevision &+= 1; return record
    }
    @discardableResult public func updateBookmark(_ id: UUID, bookmark: UUID, url: String? = nil, title: String? = nil) throws -> BrowserBookmark {
        var request = BrowserRequest(.bookmarkUpdate, browserID: id); request.bookmarkID = bookmark; request.url = url; request.title = title; try request.validate()
        let record = try records(id).updateBookmark(bookmark, url: url, title: title); recordsRevision &+= 1; return record
    }
    public func removeBookmark(_ id: UUID, bookmark: UUID) throws {
        try records(id).removeBookmark(bookmark); recordsRevision &+= 1
    }
    private func commit(_ profiles: [BrowserProfile]) throws {
        guard readable else { throw BrowserError(failure ?? "The browser library could not be read.") }
        let data = try JSONEncoder().encode(Archive(profiles: profiles))
        guard data.count <= 16 * 1_048_576 else { throw BrowserError("Browser library is full.") }
        try data.write(to: root.appendingPathComponent("browsers.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        self.profiles = profiles
    }
    public func directory(_ id: UUID, category: String) throws -> URL {
        _ = try profile(id)
        guard ["Downloads", "Uploads", "Captures"].contains(category) else { throw BrowserError("Invalid browser storage category.") }
        let url = root.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent(category)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    public static func safeFilename(_ name: String) -> String {
        let leaf = (name as NSString).lastPathComponent
        let cleaned = leaf.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == ":" || $0 == "\\" ? "_" : String($0) }.joined()
        let result = String(cleaned.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == "." || result == ".." ? "download" : result
    }
}
