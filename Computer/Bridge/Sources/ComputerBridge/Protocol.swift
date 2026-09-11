import Foundation

public struct ComputerBridgeError: LocalizedError, Sendable {
    public let message: String
    public let unavailable: Bool
    public init(_ message: String, unavailable: Bool = false) { self.message = message; self.unavailable = unavailable }
    public var errorDescription: String? { message }
}

public struct RemoteComputer: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: String
    public var state: String
    public var symbol: String
    public var colour: Int
    public var icon: Data?
    public var hasWebDisplay: Bool?
    public init(id: UUID, name: String, kind: String, state: String, symbol: String, colour: Int = 0, icon: Data? = nil, hasWebDisplay: Bool? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.state = state
        self.symbol = symbol; self.colour = colour; self.icon = icon
        self.hasWebDisplay = hasWebDisplay
    }
}

public enum ComputerOperation: String, Codable, Sendable {
    case list, start, terminalOpen, terminalRead, terminalWrite, terminalResize, terminalClose, terminalResolve, revoke, preview, display
    case fileUpload, fileDownload
    public var isFileTransfer: Bool { self == .fileUpload || self == .fileDownload }
    public var timeout: Int { isFileTransfer ? 600 : (self == .start ? 180 : 120) }
}

public struct ComputerRequest: Codable, Sendable {
    public var version = 1
    public var id = UUID()
    public var operation: ComputerOperation
    public var computerID: UUID?
    public var agentID: UUID?
    public var terminalID: UUID?
    public var data: Data?
    public var offset: Int64?
    public var columns: Int?
    public var rows: Int?
    public var view: String?
    public var capabilitiesOnly: Bool?
    public var path: String?
    /// Broker-generated reference in the shared App Group, never a host path.
    public var transferID: UUID?
    public init(_ operation: ComputerOperation, computerID: UUID? = nil, agentID: UUID? = nil,
                terminalID: UUID? = nil, data: Data? = nil, offset: Int64? = nil, columns: Int? = nil, rows: Int? = nil) {
        self.operation = operation; self.computerID = computerID; self.agentID = agentID
        self.terminalID = terminalID; self.data = data; self.offset = offset; self.columns = columns; self.rows = rows
    }
    public func validate() throws {
        guard version == 1, (data?.count ?? 0) <= 65_536, (offset ?? 0) >= 0 else {
            throw ComputerBridgeError("Unsupported or oversized computer request.")
        }
        if operation == .preview {
            guard computerID != nil || terminalID != nil else { throw ComputerBridgeError("Specify --computer or --terminal.") }
            guard view == nil || ["terminal", "web"].contains(view!) else { throw ComputerBridgeError("Invalid preview view.") }
        } else if ![.list, .terminalResolve].contains(operation), computerID == nil {
            throw ComputerBridgeError("Specify a computer.")
        }
        if [.terminalRead, .terminalWrite, .terminalResize, .terminalClose, .terminalResolve].contains(operation), terminalID == nil {
            throw ComputerBridgeError("Specify a terminal session.")
        }
        if operation == .terminalResize && (!(1...500).contains(columns ?? 0) || !(1...200).contains(rows ?? 0)) {
            throw ComputerBridgeError("Invalid terminal dimensions.")
        }
        if operation.isFileTransfer {
            guard let path, path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096,
                  terminalID == nil, data == nil else {
                throw ComputerBridgeError("Specify an absolute guest file path; file transfers do not use a terminal or inline data.")
            }
        } else if path != nil || transferID != nil {
            throw ComputerBridgeError("File fields require a file-transfer operation.")
        }
    }
}

public struct ComputerResponse: Codable, Sendable {
    public var version = 1
    public var capabilities: ComputerCapabilities?
    public var computers: [RemoteComputer]?
    public var terminalID: UUID?
    public var computerID: UUID?
    public var view: String?
    public var data: Data?
    public var offset: Int64?
    public var truncated: Bool?
    public var exited: Bool?
    public var error: String?
    public var previewImage: Data?
    /// UI-only ephemeral credentials, never stored in a card or returned to agents.
    public var display: ComputerWebConnection?
    public var path: String?
    public var byteCount: Int64?
    public init(computers: [RemoteComputer]? = nil, terminalID: UUID? = nil, data: Data? = nil,
                offset: Int64? = nil, truncated: Bool? = nil, exited: Bool? = nil, error: String? = nil) {
        self.computers = computers; self.terminalID = terminalID; self.data = data; self.offset = offset
        self.truncated = truncated; self.exited = exited; self.error = error
    }
    public func checked() throws -> Self {
        guard version == 1 else { throw ComputerBridgeError(version > 1 ? "Update Noodle to connect to this version of Noodle Computer." : "Update Noodle Computer to connect to this version of Noodle.") }
        if let error { throw ComputerBridgeError(error) }
        return self
    }
}

/// Discovery is the stable handshake. App release numbers are deliberately not
/// compared: compatible releases can ship independently.
public struct ComputerCapabilities: Codable, Equatable, Sendable {
    public var minimumProtocol = 1
    public var maximumProtocol = 1
    private static let requiredFeatures: Set<String> = ["agent-terminals-v1", "presentation-v2", "guest-display-v1"]
    public var features: Set<String> = requiredFeatures.union(["file-transfer-v1"])
    public init() {}
    public static func requireCompatible(_ capabilities: Self?) throws {
        guard let capabilities else {
            throw ComputerBridgeError("Update Noodle Computer: this version does not advertise the capabilities Noodle needs.")
        }
        guard capabilities.minimumProtocol <= capabilities.maximumProtocol else {
            throw ComputerBridgeError("Noodle Computer returned invalid compatibility information. Update Noodle Computer.")
        }
        guard capabilities.minimumProtocol <= 1 else {
            throw ComputerBridgeError("Update Noodle: Noodle Computer requires a newer connection protocol.")
        }
        guard capabilities.maximumProtocol >= 1, requiredFeatures.isSubset(of: capabilities.features) else {
            throw ComputerBridgeError("Update Noodle Computer: this version does not support the computer and preview features Noodle needs.")
        }
    }
    public static func requireFileTransfer(_ capabilities: Self?) throws {
        try requireCompatible(capabilities)
        guard capabilities?.features.contains("file-transfer-v1") == true else {
            throw ComputerBridgeError("Update Noodle Computer to upload and download files.")
        }
    }
}

public enum ComputerPresentation {
    /// Only pass sessions already filtered to the requesting owner and computer.
    public static func terminal(explicit: UUID?, active: [UUID]) throws -> UUID {
        if let explicit { return explicit }
        guard !active.isEmpty else { throw ComputerBridgeError("No active terminal. Use computer open --computer UUID first, then present --terminal SESSION_ID.") }
        guard active.count == 1 else { throw ComputerBridgeError("Multiple terminals are open. Choose one with present --terminal SESSION_ID.") }
        return active[0]
    }
}

/// Conversation-owned reference, never a network address or bearer credential.
public struct ComputerCard: Codable, Hashable, Sendable {
    public static let mediaType = "application/vnd.noodle.computer+json"
    public var version = 1
    public var computer: RemoteComputer
    public var agentID: UUID
    public var terminalID: UUID?
    public var capturedAt: Date
    public var terminalPreview: String
    public var view: String?
    public var previewImage: Data?
    public init(computer: RemoteComputer, agentID: UUID, terminalID: UUID? = nil, terminalPreview: String, view: String? = nil, previewImage: Data? = nil) {
        self.computer = computer; self.agentID = agentID; self.terminalID = terminalID
        self.capturedAt = Date(); self.terminalPreview = String(terminalPreview.suffix(2000))
        self.view = view; self.previewImage = previewImage
    }
}

/// A bounded replay buffer. Readers have independent offsets; nobody consumes another viewer's bytes.
public struct TerminalReplay: Sendable {
    public let limit: Int
    private var bytes = Data()
    public private(set) var end: Int64 = 0
    public init(limit: Int = 262_144) { self.limit = max(1, limit) }
    public mutating func append(_ data: Data) {
        end += Int64(data.count)
        bytes.append(data.suffix(limit))
        if bytes.count > limit { bytes.removeFirst(bytes.count - limit) }
    }
    public func read(from offset: Int64) -> ComputerResponse {
        let start = end - Int64(bytes.count)
        let position = max(start, min(offset, end))
        let data = Data(bytes.dropFirst(Int(position - start)).prefix(65_536))
        return .init(data: data, offset: position + Int64(data.count), truncated: offset < start || offset > end)
    }
}
