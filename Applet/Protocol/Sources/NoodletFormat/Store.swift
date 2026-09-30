import Foundation

/// Where a noodlet keeps its data files and secrets. On the Mac that runs it they are its own
/// folder and Keychain item; on a device running a Hub's noodlet they stay on the Hub, which
/// answers each call.
public protocol NoodletStore: Sendable {
    func perform(_ call: NoodletStoreCall) async throws -> NoodletValue
}

/// One call a page makes on what it keeps: `read` or `write` of a data file, or a `secret`
/// with its `action` of get, set, delete or names. It travels unchanged to wherever the
/// noodlet's data lives.
public struct NoodletStoreCall: Codable, Sendable, Equatable {
    public var operation: String
    public var path: String?
    public var text: String?
    public var action: String?
    public var name: String?
    public var value: String?

    public init(operation: String, path: String? = nil, text: String? = nil, action: String? = nil,
                name: String? = nil, value: String? = nil) {
        self.operation = operation
        self.path = path
        self.text = text
        self.action = action
        self.name = name
        self.value = value
    }

    public static let operations: Set<String> = ["read", "write", "secret"]

    /// The call in a page's bridge message, or nil when the message is about something else.
    public init?(page body: [String: Any]) {
        guard let operation = body["operation"] as? String, Self.operations.contains(operation) else { return nil }
        self.init(operation: operation, path: body["path"] as? String, text: body["text"] as? String,
                  action: body["action"] as? String, name: body["name"] as? String, value: body["value"] as? String)
    }
}

/// What a store call answers, as the page receives it.
public enum NoodletValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case text(String)
    case names([String])

    /// As WebKit hands it to the page.
    public var object: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .text(let value): value
        case .names(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let flag = try? value.decode(Bool.self) { self = .bool(flag) }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else { self = .names(try value.decode([String].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let flag): try value.encode(flag)
        case .text(let text): try value.encode(text)
        case .names(let names): try value.encode(names)
        }
    }
}
