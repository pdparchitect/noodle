import Foundation
import Darwin
import LocalMacPrivate

public struct LocalMacError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Encoded preview dimensions, not the background display's resolution.
/// Keep the existing type and `display` wire key compatible with retained accounts.
public struct LocalMacDisplay: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int = 1280, height: Int = 800) { self.width = width; self.height = height }
    public func validate() throws {
        guard (800...1920).contains(width), (600...1200).contains(height), width % 2 == 0, height % 2 == 0 else {
            throw LocalMacError("Choose an even preview size between 800 × 600 and 1920 × 1200.")
        }
    }
    /// Map a point in the encoded image through its aspect-fit padding.
    public func desktopPoint(x: Double, y: Double, bounds: CGRect, clamp: Bool = false) -> CGPoint? {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
              bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let scale = min(Double(width) / bounds.width, Double(height) / bounds.height)
        let contentWidth = bounds.width * scale, contentHeight = bounds.height * scale
        let px = x * Double(width) - (Double(width) - contentWidth) / 2
        let py = y * Double(height) - (Double(height) - contentHeight) / 2
        guard clamp || (px >= 0 && py >= 0 && px <= contentWidth && py <= contentHeight) else { return nil }
        return CGPoint(x: bounds.minX + min(bounds.width, max(0, px / scale)),
                       y: bounds.minY + min(bounds.height, max(0, py / scale)))
    }
}

public struct LocalMacAccount: Codable, Equatable, Sendable {
    public var computerID: UUID
    public var ownerUID: UInt32
    public var uid: UInt32
    public var directoryID: UUID
    public var display: LocalMacDisplay
    public var provisioned = false
    public var name: String { Self.name(for: computerID) }
    public var home: String { "/Users/" + name }
    public static func name(for id: UUID) -> String { "noodle_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20) }
    public init(computerID: UUID, ownerUID: UInt32, uid: UInt32, directoryID: UUID, display: LocalMacDisplay) {
        self.computerID = computerID; self.ownerUID = ownerUID; self.uid = uid; self.directoryID = directoryID; self.display = display
    }
    public func validate(owner: UInt32) throws {
        try display.validate()
        guard owner >= 501, ownerUID == owner, uid >= 501, uid != owner else { throw LocalMacError("Local Mac account ownership does not match.") }
    }
}

public struct LocalMacSession: Codable, Equatable, Sendable {
    public var account: LocalMacAccount
    public var id: UInt32
    public var auditID: UInt32
    public var sessionID: UUID
    public init(account: LocalMacAccount, record: [String: Any]) throws {
        guard let id = record["kCGSSessionIDKey"] as? NSNumber,
              let audit = record["kCGSSessionAuditIDKey"] as? NSNumber,
              let text = record["CGSSessionUniqueSessionUUID"] as? String, let unique = UUID(uuidString: text),
              (record["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == account.uid,
              record["kCGSSessionOnConsoleKey"] as? Bool == false,
              record["kCGSessionLoginDoneKey"] as? Bool == true else { throw LocalMacError("The account has not completed its background login.") }
        self.account = account; self.id = id.uint32Value; self.auditID = audit.uint32Value; self.sessionID = unique
    }
    public func matches(_ record: [String: Any]) -> Bool {
        (record["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == account.uid &&
        (record["kCGSSessionAuditIDKey"] as? NSNumber)?.uint32Value == auditID &&
        (record["CGSSessionUniqueSessionUUID"] as? String).flatMap(UUID.init(uuidString:)) == sessionID &&
        record["kCGSSessionUserNameKey"] as? String == account.name &&
        record["kCGSSessionOnConsoleKey"] as? Bool == false && record["kCGSessionLoginDoneKey"] as? Bool == true
    }
    public func verifyCurrent() throws {
        guard getuid() == account.uid, geteuid() == account.uid, account.uid != account.ownerUID,
              matches(NLMCopyCurrentSession() as! [String: Any]) else { throw LocalMacError("Desktop operation refused outside its assigned background session.") }
    }
}

/// The service accepts lifecycle operations only. No command, executable path,
/// home path, password, or caller-supplied UID crosses the privileged boundary.
@objc public protocol LocalMacLifecycle {
    func check(reply: @escaping () -> Void)
    func serviceInfo(reply: @escaping (Data?, String?) -> Void)
    func prepare(_ id: UUID, display: Data, reply: @escaping (Data?, String?) -> Void)
    func connect(_ id: UUID, reply: @escaping (Data?, FileHandle?, FileHandle?, String?) -> Void)
    func stop(_ id: UUID, reply: @escaping (String?) -> Void)
    func remove(_ id: UUID, reply: @escaping (String?) -> Void)
}

public enum LocalMacOperation: String, Codable, Sendable {
    case status, screenshot, stream, input, terminalOpen, terminalRead, terminalWrite, terminalResize, terminalClose
    case fileHome, fileList, fileStat, fileRead, fileWrite, fileMkdir, fileRemove, fileRename, fileCopy
    case fileUploadOpen, fileUploadCommit, fileUploadCancel
}
public struct LocalMacRequest: Codable, Sendable {
    public var protocolVersion: Int? = LocalMacWire.version
    public var id = UUID()
    public var operation: LocalMacOperation
    public var terminalID: UUID?
    public var data: Data?
    public var path: String?
    public var destination: String?
    public var version: String?
    public var transferID: UUID?
    public var size: Int64?
    public var offset: Int64?
    public var width: Int?
    public var height: Int?
    public var enabled: Bool?
    public var input: LocalMacInput?
    public var protectedDisplayIDs: [UInt32]?
    public init(_ operation: LocalMacOperation) { self.operation = operation }
    public func validate() throws {
        try LocalMacWire.checkVersion(protocolVersion)
        guard (data?.count ?? 0) <= 262_144, (offset ?? 0) >= 0,
              (path?.utf8.count ?? 0) <= 4096, !(path?.utf8.contains(0) ?? false) else { throw LocalMacError("Invalid desktop request.") }
        guard (destination?.utf8.count ?? 0) <= 4096, !(destination?.utf8.contains(0) ?? false),
              (version?.utf8.count ?? 0) <= 200, (0...LocalMacFileStore.fileLimit).contains(size ?? 0) else {
            throw LocalMacError("Invalid file request.")
        }
        if operation == .terminalResize {
            guard (1...500).contains(width ?? 0), (1...200).contains(height ?? 0) else { throw LocalMacError("Invalid terminal size.") }
        }
        if operation == .input { guard let input else { throw LocalMacError("Missing input event.") }; try input.validate() }
        if operation == .stream, enabled == true {
            try LocalMacCapturePolicy.validateProtectedDisplays(protectedDisplayIDs ?? [])
        }
    }
}
public struct LocalMacInput: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case move, down, up, scroll, keyDown, keyUp, flagsChanged, text, reset }
    public var kind: Kind
    public var x: Double = 0
    public var y: Double = 0
    public var button: Int = 0
    public var key: UInt16 = 0
    public var flags: UInt64 = 0
    public var text: String?
    public var scroll: Double = 0
    public var clickCount: Int = 1
    public init(_ kind: Kind) { self.kind = kind }
    public func validate() throws {
        guard x.isFinite, y.isFinite, scroll.isFinite, abs(scroll) <= 10_000, (0...2).contains(button), key < 256,
              (text?.utf16.count ?? 0) <= 4096, (0...10).contains(clickCount) else { throw LocalMacError("Invalid input event.") }
    }
}
public struct LocalMacFile: Codable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: String
    public var size: Int64
    public var modified: Int64
    public var version: String
    public var directory: Bool { kind == "directory" }
}
public struct LocalMacReply: Codable, Sendable {
    public var protocolVersion: Int? = LocalMacWire.version
    public var id: UUID?
    public var error: String?
    public var data: Data?
    public var terminalID: UUID?
    public var offset: Int64?
    public var exited: Bool?
    public var files: [LocalMacFile]?
    public var homeDirectory: String?
    public var transferID: UUID?
    public var status: LocalMacStatus?
    public var frame = false
    public init(id: UUID? = nil, error: String? = nil) { self.id = id; self.error = error }
}
public struct LocalMacStatus: Codable, Sendable {
    // Keep the existing wire error recognizable by clients talking to a retained
    // 0.7.0 helper; no new reply fields or protocol version are required.
    public static let inputPermissionError = "Allow Accessibility for the desktop helper to control this account."
    public var screenCapture: Bool
    public var accessibility: Bool
    public var postEvents: Bool
    public var display: LocalMacDisplay
    public var displayID: UInt32?
    public var setupRunning: Bool
    public var detail: String?
    public var canControl: Bool { accessibility && postEvents }
    public init(screenCapture: Bool, accessibility: Bool, postEvents: Bool, display: LocalMacDisplay,
                setupRunning: Bool = false, detail: String? = nil) {
        self.screenCapture = screenCapture; self.accessibility = accessibility; self.postEvents = postEvents
        self.display = display
        self.setupRunning = setupRunning; self.detail = detail
    }
}

/// Bounded binary framing. Video is disposable; never write a recording to disk.
public enum LocalMacWire {
    public static let version = 1
    public static let maximum = 12 * 1_048_576
    public static func checkVersion(_ version: Int?) throws {
        guard version == Self.version else {
            throw LocalMacError("Noodle Computer and its desktop helper are incompatible. Update Noodle Computer, then stop and start this computer; its account and permissions are retained.")
        }
    }
    private struct Version: Decodable { var protocolVersion: Int? }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        try checkVersion(decoder.decode(Version.self, from: data).protocolVersion)
        return try decoder.decode(type, from: data)
    }
    public static func read(_ handle: FileHandle) throws -> Data? {
        func exact(_ count: Int, eof: Bool = false) throws -> Data? {
            var data = Data()
            while data.count < count {
                guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else {
                    if data.isEmpty && eof { return nil }; throw LocalMacError("Desktop connection ended mid-message.")
                }
                data.append(next)
            }
            return data
        }
        guard let header = try exact(4, eof: true) else { return nil }
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximum else { throw LocalMacError("Desktop message exceeds the size limit.") }
        return try exact(count)
    }
    public static func write(_ data: Data, to handle: FileHandle) throws {
        guard !data.isEmpty, data.count <= maximum else { throw LocalMacError("Desktop message exceeds the size limit.") }
        var size = UInt32(data.count).bigEndian
        var packet = withUnsafeBytes(of: &size) { Data($0) }; packet.append(data)
        try handle.write(contentsOf: packet)
    }
}
