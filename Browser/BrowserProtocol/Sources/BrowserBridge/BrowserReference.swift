import Foundation

/// A saved page reference. It contains no cookies, credentials or agent authority.
public struct BrowserReference: Codable, Hashable, Sendable {
    public static let maximumBytes = 900_000
    public static let mediaType = "application/vnd.noodle.browser+json"
    public var version = 1
    public var browser: RemoteBrowser
    public var tabID: UUID
    public var url: String
    public var title: String
    public var capturedAt: Date
    public var previewImage: Data?
    public init(browser: RemoteBrowser, tabID: UUID, url: String, title: String,
                capturedAt: Date = Date(), previewImage: Data? = nil) {
        self.browser = browser; self.tabID = tabID; self.url = url; self.title = title
        // Conversation metadata stores ISO-8601 dates at whole-second precision.
        // Keep its reference identical to the separately encoded document.
        self.capturedAt = Date(timeIntervalSince1970: capturedAt.timeIntervalSince1970.rounded(.down))
        self.previewImage = previewImage
    }
    public func validate() throws {
        guard version == 1, browser.name.count <= 120, title.utf8.count <= 2048,
              (browser.icon?.count ?? 0) <= 65_536, (previewImage?.count ?? 0) <= 550_000 else {
            throw BrowserError("This browser reference is unsupported or too large.")
        }
        _ = try BrowserRequest.navigationURL(url)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw BrowserError("This browser reference is too large.") }
        let reference = try JSONDecoder().decode(Self.self, from: data)
        try reference.validate(); return reference
    }
    public static func read(_ url: URL, build: BrowserBuildIdentity = .current) throws -> Self {
        guard url.isFileURL, url.pathExtension.lowercased() == build.fileExtension else {
            throw BrowserError("Open a .\(build.fileExtension) file in \(build.appName).")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else {
            throw BrowserError("This browser reference is not a supported file.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try decode(file.read(upToCount: maximumBytes + 1) ?? Data())
    }
}

/// The presenting agent belongs to conversation metadata, never to the file.
public struct BrowserCard: Codable, Hashable, Sendable {
    public var reference: BrowserReference
    public var agentID: UUID
    public init(reference: BrowserReference, agentID: UUID) { self.reference = reference; self.agentID = agentID }
}
