import Foundation

/// Where a noodlet keeps its data files and secrets. On the Mac that runs it they are its own
/// folder and Keychain item; on a device running a Hub's noodlet they stay on the Hub, which
/// answers each call.
public protocol NoodletStore: Sendable {
    func perform(_ call: NoodletStoreCall) async throws -> NoodletValue
}

/// One call a page makes on what it keeps: `read` or `write` of a data file, whose bytes travel
/// as base64 in `data`; `list` of the files under the `path` prefix; or a `secret` with its
/// `action` of get, set, delete or names. It travels unchanged to wherever the noodlet's data lives.
public struct NoodletStoreCall: Codable, Sendable, Equatable {
    public var operation: String
    public var path: String?
    /// A file's bytes, base64-encoded.
    public var data: String?
    public var action: String?
    public var name: String?
    public var value: String?

    public init(operation: String, path: String? = nil, data: String? = nil, action: String? = nil,
                name: String? = nil, value: String? = nil) {
        self.operation = operation
        self.path = path
        self.data = data
        self.action = action
        self.name = name
        self.value = value
    }

    public static let operations: Set<String> = ["read", "write", "list", "secret"]
    /// The largest data file a page may keep: 16 MiB, as large as a fetch.
    public static let fileLimit = 16 * 1_048_576

    /// The call in a page's bridge message, or nil when the message is about something else.
    public init?(page body: [String: Any]) {
        guard let operation = body["operation"] as? String, Self.operations.contains(operation) else { return nil }
        self.init(operation: operation, path: body["path"] as? String, data: body["data"] as? String,
                  action: body["action"] as? String, name: body["name"] as? String, value: body["value"] as? String)
    }
}

/// A data file as `list` reports it: its path in the data folder, its size in bytes, and when it
/// last changed, as ISO 8601.
public struct NoodletEntry: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int
    public var modified: String

    public init(path: String, size: Int, modified: String) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

/// What a store call answers, as the page receives it. A read answers its file's bytes as base64 text.
public enum NoodletValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case text(String)
    case names([String])
    case entries([NoodletEntry])

    /// As WebKit hands it to the page.
    public var object: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .text(let value): value
        case .names(let value): value
        case .entries(let value): value.map { ["path": $0.path, "size": $0.size, "modified": $0.modified] as [String: Any] }
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let flag = try? value.decode(Bool.self) { self = .bool(flag) }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        // An empty list reads as names; the page sees the same empty array either way.
        else if let names = try? value.decode([String].self) { self = .names(names) }
        else { self = .entries(try value.decode([NoodletEntry].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let flag): try value.encode(flag)
        case .text(let text): try value.encode(text)
        case .names(let names): try value.encode(names)
        case .entries(let entries): try value.encode(entries)
        }
    }
}
