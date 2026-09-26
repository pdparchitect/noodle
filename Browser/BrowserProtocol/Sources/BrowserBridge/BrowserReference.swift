import Foundation

/// What Noodle Browser reports when a bot shares a tab: the browser, tab, page and a picture.
/// It contains no cookies, credentials or agent authority.
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
        // Every conversation member can read a card; the description is for assigned agents.
        self.browser.description = nil
        // Conversation metadata stores ISO-8601 dates at whole-second precision.
        // Keep its reference identical to the separately encoded document.
        self.capturedAt = Date(timeIntervalSince1970: capturedAt.timeIntervalSince1970.rounded(.down))
        self.previewImage = previewImage
    }
    public func validate() throws {
        guard version == 1, browser.name.count <= 120, title.utf8.count <= 2048,
              (browser.description?.count ?? 0) <= RemoteBrowser.maximumDescriptionLength,
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
}

// TODO(0.29.0): Remove with CompanionCardMigration, which is its last reader.
/// How versions up to 0.27 saved a shared browser tab beside its file.
public struct BrowserCard: Codable, Hashable, Sendable {
    public var reference: BrowserReference
    public var agentID: UUID
    public init(reference: BrowserReference, agentID: UUID) { self.reference = reference; self.agentID = agentID }
}

/// A link to a browser, and to one of its tabs: noodlebrowser://BROWSER?tab=TAB. It carries no
/// cookies, credentials or authority; whoever opens it decides whether it may.
public enum BrowserLink {
    public static func url(browser: UUID, tab: UUID?, build: BrowserBuildIdentity = .current) -> URL {
        var parts = URLComponents()
        parts.scheme = build.urlScheme
        parts.host = browser.uuidString.lowercased()
        if let tab { parts.queryItems = [URLQueryItem(name: "tab", value: tab.uuidString.lowercased())] }
        return parts.url!
    }
    public static func build(in url: URL) -> BrowserBuildIdentity? {
        BrowserBuildIdentity.allCases.first { $0.urlScheme == url.scheme?.lowercased() }
    }
    /// The browser and tab a link names, in either build. Nil for anything else.
    public static func target(in url: URL) -> (browser: UUID, tab: UUID?)? {
        guard build(in: url) != nil, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.path.isEmpty, parts.fragment == nil,
              let browser = parts.host.flatMap(UUID.init(uuidString:)) else { return nil }
        let items = parts.queryItems ?? []
        guard items.allSatisfy({ $0.name == "tab" }), items.count <= 1 else { return nil }
        if let value = items.first?.value {
            guard let tab = UUID(uuidString: value) else { return nil }
            return (browser, tab)
        }
        return (browser, nil)
    }
}
