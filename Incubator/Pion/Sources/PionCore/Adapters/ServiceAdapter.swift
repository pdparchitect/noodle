import Foundation
import NoodleCore
import NoodleMCP

/// How an adapter's operations reach their service. In the app it is the connection's guarded access, which
/// adds its credentials and reaches only its host.
public protocol ServiceAccess: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension MCPAdapterAccess: ServiceAccess {}

/// A tool's input, described in code; bots see it as JSON Schema.
public indirect enum JSONSchema: Sendable {
    case string(String, oneOf: [String]? = nil)
    case integer(String, minimum: Int? = nil, maximum: Int? = nil)
    case boolean(String)
    case array(JSONSchema, String)
    case object([String: JSONSchema], required: [String] = [], description: String? = nil)

    var json: [String: Any] {
        switch self {
        case .string(let description, let values):
            var schema: [String: Any] = ["type": "string", "description": description]
            if let values { schema["enum"] = values }
            return schema
        case .integer(let description, let minimum, let maximum):
            var schema: [String: Any] = ["type": "integer", "description": description]
            if let minimum { schema["minimum"] = minimum }
            if let maximum { schema["maximum"] = maximum }
            return schema
        case .boolean(let description):
            return ["type": "boolean", "description": description]
        case .array(let items, let description):
            return ["type": "array", "items": items.json, "description": description]
        case .object(let properties, let required, let description):
            var schema: [String: Any] = ["type": "object", "properties": properties.mapValues(\.json)]
            if !required.isEmpty { schema["required"] = required }
            if let description { schema["description"] = description }
            return schema
        }
    }
}

/// One thing an adapter can do: a typed input, and the requests that answer it. Operations are values, so an
/// adapter is a list of them and one operation can serve several adapters.
public protocol ServiceOperation: Sendable {
    associatedtype Input: Decodable & Sendable
    /// What bots call it: lowercase words joined by hyphens.
    static var name: String { get }
    static var summary: String { get }
    static var input: JSONSchema { get }
    /// Whether it only reads. Bots are told; it is a hint, not a permission.
    static var readOnly: Bool { get }
    func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult
}

public extension ServiceOperation {
    static var readOnly: Bool { true }
}

/// What an operation gives back: a sentence or two for the bot to read, and the fields it kept, as JSON.
public struct ServiceResult: Sendable {
    let text: String
    let structured: Data?

    public init(text: String) { self.text = text; structured = nil }

    /// `structured` must encode as a JSON object.
    public init(text: String, structured: some Encodable) throws {
        self.text = text
        self.structured = try JSONEncoder().encode(structured)
    }
}

/// Why an operation could not finish, said so the bot can act on it.
public enum ServiceError: LocalizedError, Equatable, Sendable {
    case notFound
    case rejected
    case rateLimited
    case status(Int)
    case unreadable
    case input(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "The service has not found it (HTTP 404)."
        case .rejected: "The service rejected this connection's credentials. Ask the person to check them in Settings › Tools."
        case .rateLimited: "The service is rate limiting requests (HTTP 429). Wait before trying again, and make fewer requests."
        case .status(let status): "The service could not answer (HTTP \(status))."
        case .unreadable: "The service answered with something that could not be read."
        case .input(let reason): reason
        }
    }
}

/// Requests to the connection's service, below its address: paths are built from separate parts, so no value
/// can climb out of the operation's own path, and every answer is checked before it is read.
public struct ServiceClient: Sendable {
    let base: URL
    let access: any ServiceAccess

    /// `path`'s parts each go in as one segment; a part that would leave it is refused.
    public func get<Answer: Decodable>(_ path: [String], query: [String: String?] = [:],
                                       as answer: Answer.Type = Answer.self) async throws -> Answer {
        let data = try await data(path, query: query)
        do { return try JSONDecoder().decode(Answer.self, from: data) } catch { throw ServiceError.unreadable }
    }

    public func data(_ path: [String], query: [String: String?] = [:]) async throws -> Data {
        for part in path where part.isEmpty || part == "." || part == ".." || part.contains(where: { "/?#\\".contains($0) }) {
            throw ServiceError.input("\"\(part)\" is not a valid value here.")
        }
        var components = URLComponents(url: path.reduce(base) { $0.appendingPathComponent($1) }, resolvingAgainstBaseURL: false)
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }.sorted { $0.name < $1.name }
        components?.queryItems = items.isEmpty ? nil : items
        guard let url = components?.url else { throw ServiceError.input("These values make no valid request.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await access.data(for: request)
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw ServiceError.rejected
        case 404: throw ServiceError.notFound
        case 429: throw ServiceError.rateLimited
        default: throw ServiceError.status(response.statusCode)
        }
    }
}

/// An adapter made of operations. Its tools are the operations' names and schemas; a call decodes the
/// operation's input and runs it. A failure the bot can act on comes back as an error result, not a fault.
public struct OperationAdapter: MCPConnectionAdapter {
    private struct Entry: Sendable {
        /// The tool as listed, in JSON.
        let tool: Data
        let run: @Sendable (Data, ServiceClient) async throws -> ServiceResult
    }
    private let entries: [(name: String, entry: Entry)]

    public init(operations: [any ServiceOperation]) {
        entries = operations.map { Self.entry($0) }
    }

    private static func entry<Operation: ServiceOperation>(_ operation: Operation) -> (name: String, entry: Entry) {
        let description: [String: Any] = [
            "name": Operation.name, "description": Operation.summary,
            "annotations": ["readOnlyHint": Operation.readOnly], "inputSchema": Operation.input.json,
        ]
        let tool = (try? JSONSerialization.data(withJSONObject: description, options: [.sortedKeys])) ?? Data("{}".utf8)
        return (Operation.name, Entry(tool: tool) { arguments, client in
            let input: Operation.Input
            do { input = try JSONDecoder().decode(Operation.Input.self, from: arguments) }
            catch { throw ServiceError.input(Self.reason(error)) }
            return try await operation.run(input, on: client)
        })
    }

    public func tools(for connection: MCPConnectionRecord) async throws -> Data {
        let tools = try entries.map { try JSONSerialization.jsonObject(with: $0.entry.tool) }
        return try JSONSerialization.data(withJSONObject: ["tools": tools], options: [.sortedKeys])
    }

    public func call(_ tool: String, arguments: Data, connection: MCPConnectionRecord, access: MCPAdapterAccess) async throws -> Data {
        try await run(tool, arguments: arguments, connection: connection, access: access)
    }

    /// A call through any access, so operations can be tried against a stand-in service.
    func run(_ tool: String, arguments: Data, connection: MCPConnectionRecord, access: any ServiceAccess) async throws -> Data {
        guard let entry = entries.first(where: { $0.name == tool })?.entry else {
            throw MCPConnectionError.message("This connection does not offer \(tool).")
        }
        do {
            let result = try await entry.run(arguments, ServiceClient(base: connection.endpoint, access: access))
            var object: [String: Any] = ["content": [["type": "text", "text": result.text]], "isError": false]
            if let structured = result.structured { object["structuredContent"] = try JSONSerialization.jsonObject(with: structured) }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch let error as ServiceError {
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": error.localizedDescription]],
                                                               "isError": true], options: [.sortedKeys])
        }
    }

    /// What was wrong with the input, naming the field.
    private static func reason(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "\(key.stringValue) is required."
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            "\(context.codingPath.map(\.stringValue).joined(separator: ".")) has the wrong type."
        default: "The input is not valid JSON for this tool."
        }
    }
}

/// The adapters Pion serves its own connections with, by the name its catalogue entries give them.
public enum PionAdapters {
    public static let all: [String: any MCPConnectionAdapter] = ["virustotal": VirusTotal.adapter, "okta": Okta.adapter]
}
