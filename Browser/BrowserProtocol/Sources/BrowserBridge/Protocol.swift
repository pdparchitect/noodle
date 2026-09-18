import Foundation

public struct BrowserError: LocalizedError, Sendable {
    public let message: String
    public let unavailable: Bool
    public var errorDescription: String? { message }
    public init(_ message: String, unavailable: Bool = false) { self.message = message; self.unavailable = unavailable }
}

public enum BrowserOperation: String, Codable, CaseIterable, Sendable {
    case list, status, tabs, open, navigate, back, forward, reload, close
    case inspect, eval, click, fill, key, scroll, screenshot, upload, downloads, download, dialog, show, present
    case move, mouseReset = "mouse-reset"
    case history, bookmarks
    case webMCPList = "webmcp-list", webMCPCall = "webmcp-call"
    case bookmarkAdd = "bookmark-add", bookmarkUpdate = "bookmark-update", bookmarkRemove = "bookmark-remove"
    public var timeout: Int { isFileTransfer ? 600 : 60 }
    public var isFileTransfer: Bool { self == .upload || self == .download || self == .screenshot }
    public var needsTab: Bool { ![.list, .status, .tabs, .open, .downloads, .download, .show, .history, .bookmarks, .bookmarkAdd, .bookmarkUpdate, .bookmarkRemove].contains(self) }
}

public struct BrowserPointerState: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var visible: Bool
    public var pressed: Bool
    public init(x: Double, y: Double, visible: Bool, pressed: Bool) {
        self.x = x; self.y = y; self.visible = visible; self.pressed = pressed
    }
}

public struct BrowserHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    /// ISO 8601 UTC timestamp.
    public var visitedAt: String
    public init(id: UUID, url: String, title: String, visitedAt: String) {
        self.id = id; self.url = url; self.title = title; self.visitedAt = visitedAt
    }
}
public struct BrowserBookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    public init(id: UUID, url: String, title: String, createdAt: String, updatedAt: String) {
        self.id = id; self.url = url; self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct RemoteBrowser: Codable, Identifiable, Hashable, Sendable {
    public static let maximumDescriptionLength = 500
    public var id: UUID
    public var name: String
    /// What the user keeps this browser for; tells an agent which assigned browser fits a task.
    public var description: String?
    public var symbol: String
    public var colour: Int
    public var icon: Data?
    public var muted: Bool
    public var paused: Bool
    public var tabCount: Int
    public init(id: UUID, name: String, description: String? = nil, symbol: String = "globe", colour: Int = 0, icon: Data? = nil, muted: Bool = true, paused: Bool = false, tabCount: Int = 0) {
        self.id = id; self.name = name; self.description = description; self.symbol = symbol; self.colour = colour
        self.icon = icon
        self.muted = muted; self.paused = paused; self.tabCount = tabCount
    }
}
public struct BrowserTabInfo: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String
    public var loading: Bool
    public var error: String?
    public init(id: UUID = UUID(), title: String = "New Tab", url: String = "about:blank", loading: Bool = false, error: String? = nil) {
        self.id = id; self.title = title; self.url = url; self.loading = loading; self.error = error
    }
}
public struct BrowserDownloadInfo: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var filename: String
    public var state: String
    public var byteCount: Int64
    public var error: String?
    public init(id: UUID = UUID(), filename: String, state: String = "downloading", byteCount: Int64 = 0, error: String? = nil) {
        self.id = id; self.filename = filename; self.state = state; self.byteCount = byteCount; self.error = error
    }
}
public struct BrowserDialog: Codable, Equatable, Sendable {
    public var kind: String
    public var message: String
    public var defaultText: String?
    public var origin: String
    public init(kind: String, message: String, defaultText: String? = nil, origin: String) {
        self.kind = kind; self.message = message; self.defaultText = defaultText; self.origin = origin
    }
}
public struct BrowserRequest: Codable, Sendable {
    public var version = 1
    public var id = UUID()
    public var operation: BrowserOperation
    public var browserID: UUID?
    public var tabID: UUID?
    public var url: String?
    public var target: String?
    public var frame: String?
    public var text: String?
    public var x: Double?
    public var y: Double?
    public var clickCount: Int?
    public var fileID: UUID?
    public var transferID: UUID?
    public var filename: String?
    public var accept: Bool?
    public var bookmarkID: UUID?
    public var title: String?
    public var query: String?
    public var limit: Int?
    public var offset: Int?
    public var toolID: String?
    /// JSON object encoded as UTF-8 text; never interpreted as JavaScript source.
    public var arguments: String?
    public init(_ operation: BrowserOperation, browserID: UUID? = nil, tabID: UUID? = nil) {
        self.operation = operation; self.browserID = browserID; self.tabID = tabID
    }
    public func validate() throws {
        try validateWebMCP()
        guard version == 1 else { throw BrowserError("Update Noodle and Noodle Browser to compatible versions.") }
        guard operation == .list || browserID != nil else { throw BrowserError("Specify --browser UUID.") }
        guard !operation.needsTab || tabID != nil else { throw BrowserError("Specify --tab UUID from tabs or open.") }
        for value in [target, frame, filename] { if let value, value.utf8.count > 4096 || value.utf8.contains(0) { throw BrowserError("Invalid browser argument.") } }
        if let text, text.utf8.count > 1_048_576 { throw BrowserError("Browser script or text exceeds 1 MiB.") }
        for value in [x, y] { if let value, !value.isFinite || abs(value) > 100_000 { throw BrowserError("Invalid coordinate.") } }
        if operation == .navigate || (operation == .open && url != nil) { _ = try Self.navigationURL(url ?? "") }
        if [.fill, .upload].contains(operation), target?.isEmpty != false { throw BrowserError("Specify --target CSS_SELECTOR.") }
        if operation == .click, target?.isEmpty != false, x == nil || y == nil { throw BrowserError("Specify --target or --x and --y.") }
        if [.move, .click].contains(operation) {
            if target != nil && (x != nil || y != nil) { throw BrowserError("Use --target or --x and --y, not both.") }
            if (x == nil) != (y == nil) { throw BrowserError("Specify both --x and --y.") }
            if let target, target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw BrowserError("Specify a nonempty --target.") }
            if operation == .move && target == nil && x == nil { throw BrowserError("Specify --target or --x and --y.") }
            if frame != nil && target == nil { throw BrowserError("--frame requires --target; coordinates use the main viewport.") }
        }
        if let clickCount, operation != .click || !(1...2).contains(clickCount) { throw BrowserError("Use --count 1 or 2 with click.") }
        if [.eval, .fill, .key].contains(operation), text == nil { throw BrowserError("Specify --text or --file.") }
        if operation == .download, fileID == nil { throw BrowserError("Specify --download UUID from downloads.") }
        if operation == .dialog, accept == nil { throw BrowserError("Specify --accept true or false.") }
        if let query, query.utf8.count > 1000 || query.utf8.contains(0) { throw BrowserError("Search must be at most 1,000 UTF-8 bytes without null characters.") }
        if let limit, !(1...200).contains(limit) { throw BrowserError("Use --limit 1–200.") }
        if let offset, !(0...Int(Int32.max)).contains(offset) { throw BrowserError("Use a nonnegative --offset up to 2147483647.") }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.utf8.count > 2048 || title.utf8.contains(0) { throw BrowserError("Bookmark title must be 1–2,048 UTF-8 bytes without null characters.") }
        if operation == .bookmarkAdd || (operation == .bookmarkUpdate && url != nil) { _ = try Self.navigationURL(url ?? "") }
        if [.bookmarkUpdate, .bookmarkRemove].contains(operation), bookmarkID == nil { throw BrowserError("Specify --bookmark UUID from bookmarks.") }
        if operation == .bookmarkUpdate, url == nil && title == nil { throw BrowserError("Specify --title and/or --url to update.") }
    }
    public static func navigationURL(_ input: String) throws -> URL {
        guard input.utf8.count <= 16_384, let url = URL(string: input),
              (url.scheme == "http" || url.scheme == "https"), url.host?.isEmpty == false,
              url.user == nil, url.password == nil, !input.utf8.contains(0) else { throw BrowserError("Use an HTTP or HTTPS URL without embedded credentials.") }
        return url
    }
}
public struct BrowserResponse: Codable, Sendable {
    public var version = 1
    public var browsers: [RemoteBrowser]?
    public var browser: RemoteBrowser?
    public var tabs: [BrowserTabInfo]?
    public var tabID: UUID?
    public var downloads: [BrowserDownloadInfo]?
    public var reference: BrowserReference?
    public var attachmentID: UUID?
    public var dialog: BrowserDialog?
    public var pointer: BrowserPointerState?
    public var text: String?
    public var byteCount: Int64?
    public var filename: String?
    public var history: [BrowserHistoryEntry]?
    public var bookmarks: [BrowserBookmark]?
    public var bookmark: BrowserBookmark?
    public var totalCount: Int?
    public var offset: Int?
    public var limit: Int?
    public var error: String?
    public init(error: String? = nil) { self.error = error }
    public func checked() throws -> Self {
        if let error { throw BrowserError(error) }
        guard version == 1 else { throw BrowserError("Incompatible Browser protocol.") }
        return self
    }
}
