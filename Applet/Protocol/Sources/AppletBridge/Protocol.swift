import Foundation

public struct AppletError: Error, LocalizedError, Sendable {
    public let message: String
    public let unavailable: Bool
    public init(_ message: String, unavailable: Bool = false) {
        self.message = message
        self.unavailable = unavailable
    }
    public var errorDescription: String? { message }
}

public enum AppletOperation: String, Codable, CaseIterable, Sendable {
    case list, info, validate, build, open, status, logs, inspect, eval, click, type, key, scroll, drag
    case screenshot
    case recordStart = "record-start"
    case recordStop = "record-stop"
    case show, hide, close, terminate, restart, artifact, present
    public var timeout: Int {
        switch self {
        case .build, .open, .restart: return 180
        case .recordStop: return 60
        default: return 30
        }
    }
    public var isFileTransfer: Bool { self == .artifact }
}

public struct AppletRequest: Codable, Sendable {
    public var id = UUID()
    public var version = 1
    public var operation: AppletOperation
    public var sessionID: UUID?
    public var noodletID: UUID?
    /// Only the signed Noodle UI may request a temporary preview access bookmark.
    public var includePreview: Bool?
    public var path: String?
    public var owner: String?
    public var files: [String: Data]?
    public var text: String?
    public var target: String?
    public var mode: String?
    public var x: Double?
    public var y: Double?
    public var toX: Double?
    public var toY: Double?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var offset: Int?
    public var artifactID: UUID?
    public init(_ operation: AppletOperation, sessionID: UUID? = nil) {
        self.operation = operation
        self.sessionID = sessionID
    }
    public func validate() throws {
        guard version == 1 else { throw AppletError("Unsupported Applet protocol version.") }
        if noodletID != nil, path != nil || sessionID != nil || files != nil {
            throw AppletError("Use --id alone, without --path, --session, or package files.")
        }
        if includePreview == true, operation != .info {
            throw AppletError("Preview access is only valid with info.")
        }
        if let mode, !["background", "foreground", "headless"].contains(mode) {
            throw AppletError("Use background, foreground, or headless mode.")
        }
        for n in [x, y, toX, toY, duration].compactMap({ $0 }) {
            guard n.isFinite, abs(n) <= 1_000_000 else {
                throw AppletError("Invalid numeric input.")
            }
        }
        for n in [width, height].compactMap({ $0 }) {
            guard (64...4096).contains(n) else {
                throw AppletError("Viewport must be 64–4096 points.")
            }
        }
        guard (text?.utf8.count ?? 0) <= 1_048_576, (offset ?? 0) >= 0 else {
            throw AppletError("Input exceeds its limit.")
        }
        if let duration, !(0...60).contains(duration) {
            throw AppletError("Duration must be 0–60 seconds.")
        }
        if let files {
            guard files.count <= 512, files.values.reduce(0, { $0 + $1.count }) <= 20 * 1_048_576
            else { throw AppletError("Packages may contain at most 512 files and 20 MiB.") }
            for name in files.keys { try Self.validateRelativePath(name) }
        }
    }
    public static func validateRelativePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), path.utf8.count < 2048
        else {
            throw AppletError("Unsafe relative path: \(path.prefix(100))")
        }
    }
}

public struct AppletResponse: Codable, Sendable {
    public var version = 1
    public var error: String?
    public var sessionID: UUID?
    public var noodletID: UUID?
    public var url: URL?
    public var title: String?
    public var runtime: String?
    public var previewBookmark: Data?
    public var state: String?
    public var path: String?
    public var text: String?
    public var value: String?
    public var offset: Int?
    public var done: Bool?
    public var data: Data?
    public var artifactID: UUID?
    public var mediaType: String?
    public var width: Int?
    public var height: Int?
    public var items: [AppletItem]?
    public var capabilities: [String]?
    public init(error: String? = nil) { self.error = error }
    public func checked() throws -> Self {
        if let error { throw AppletError(error) }
        return self
    }
}

public struct AppletItem: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var noodletID: UUID?
    public var url: URL?
    public var title: String
    public var runtime: String
    public var sessionID: UUID?
    public var state: String?
    public init(
        path: String, title: String, runtime: String, sessionID: UUID? = nil, state: String? = nil
    ) {
        self.path = path
        self.title = title
        self.runtime = runtime
        self.sessionID = sessionID
        self.state = state
    }
}

public struct AppletAgentEnvelope: Codable, Sendable {
    public var id: UUID
    public var token: String
    public var expiresAt: Date
    public var request: AppletRequest
    public var conversationID: UUID?
    public init(token: String, request: AppletRequest, conversationID: UUID? = nil) {
        self.id = request.id
        self.token = token
        self.request = request
        self.conversationID = conversationID
        expiresAt = Date().addingTimeInterval(Double(request.operation.timeout + 5))
    }
}

public struct AppletAgentSession: Codable {
    public var token: String
    public var processID: Int32
    public init(token: String, processID: Int32) {
        self.token = token
        self.processID = processID
    }
}
