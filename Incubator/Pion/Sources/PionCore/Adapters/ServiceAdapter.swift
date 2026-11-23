import Foundation
import NoodleCore
import NoodleToolConnections

/// How an adapter's operations reach their service. In the app it is the connection's guarded access, which
/// adds its credentials and reaches only its host.
public protocol ServiceAccess: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// For an AWS connection signed in through IAM Identity Center: every account its sign-in covers.
    func awsAccounts() async throws -> [AWSAccount]
    /// The same access, signing as the connection's role in one of those accounts.
    func access(asAWSAccount id: String) async throws -> any ServiceAccess
}

extension ServiceAccess {
    public func awsAccounts() async throws -> [AWSAccount] { throw ServiceError.input("This connection does not sign in to AWS.") }
    public func access(asAWSAccount id: String) async throws -> any ServiceAccess {
        throw ServiceError.input("This connection does not sign in to AWS.")
    }
}

extension ToolConnectionAccess: ServiceAccess {
    public func access(asAWSAccount id: String) async throws -> any ServiceAccess { try await awsAccount(id) }
}

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
    /// Whether it only reads. Bots are told through the tool's hints.
    static var readOnly: Bool { get }
    /// Whether it cuts off or restores someone's access, or deletes something. Noodle's tool broker then holds a bot's
    /// call for the champion's approval, as data a bot reads, such as a phishing mail, could have asked for it; an
    /// ordinary change, which is neither, runs on the bot's call.
    static var destructive: Bool { get }
    func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult
}

public extension ServiceOperation {
    static var readOnly: Bool { true }
    static var destructive: Bool { false }
}

extension ServiceAlert {
    /// A service's time to the whole second, however many digits of a second it gives: Microsoft gives seven,
    /// which the ISO 8601 parser does not take.
    static func time(_ value: String?) -> Date? {
        value.flatMap { ISO8601DateFormatter().date(from: $0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)) }
    }
}

/// What an adapter watches: its service's own feed of new and serious things, such as high alerts, read the same way
/// for every account so nothing about it is set up. One per adapter, though it may read several of the service's feeds.
public protocol ServiceTrigger: Sendable {
    /// The adapter's operation that reads what it finds in full, which the wake names.
    var tool: String { get }
    /// What is serious from `since` on, at most `ServiceAlert.most` of it, newest first.
    func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert]
    /// The same for one account, for a trigger that keeps track of an account between its checks, such as how long a
    /// report has failed; the rest need not.
    func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert]
    /// How far each check reads back from the newest alert seen, as the service lists some after their time.
    var lookBack: TimeInterval { get }
}

public extension ServiceTrigger {
    var lookBack: TimeInterval { AlertWatch.overlap }
    func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert] {
        try await check(since: since, on: service)
    }
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

    private init(text: String, encoded: Data?) { self.text = text; structured = encoded }

    /// The same result with `notice` after its text, such as what a search left out.
    func adding(_ notice: String) -> ServiceResult { ServiceResult(text: text + notice, encoded: structured) }
}

/// Why an operation could not finish, said so the bot can act on it.
public enum ServiceError: LocalizedError, Equatable, Sendable {
    case notFound
    /// The service did not accept the credentials at all (HTTP 401), saying why when it did.
    case rejected(String?)
    /// The service accepted the credentials, but they may not do this (HTTP 403), saying why when it did.
    case forbidden(String?)
    /// Too many requests (HTTP 429, or a 403 that names a quota), saying why when it did, such as which quota of which
    /// project ran out.
    case rateLimited(String? = nil)
    /// Any other failure, with the service's reason when it gave one.
    case status(Int, String? = nil)
    case unreadable
    case input(String)
    /// The service answered, but refused or failed the request, saying why.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "The service has not found it (HTTP 404)."
        case .rejected(let reason):
            "The service rejected this connection's credentials\(reason.map { " (it said: \($0))" } ?? ""): the key or token is wrong or has expired. "
                + "Ask the person to check it in Settings › Tools."
        case .forbidden(let reason):
            "The service accepted this connection's credentials, but they may not do this\(reason.map { " (it said: \($0))" } ?? ""). "
                + "Ask the person to check the permissions they were given, and the organisation, project or account the connection names, in Settings › Tools."
        case .rateLimited(let reason):
            "The service is rate limiting requests\(reason.map { "; it said: \($0)" } ?? ""). Wait before trying again, and make fewer requests."
        case .status(let status, let reason): "The service could not answer (HTTP \(status))\(reason.map { "; it said: \($0)" } ?? "")."
        case .unreadable: "The service answered with something that could not be read."
        case .input(let reason): reason
        case .refused(let reason): "The service refused the request: \(reason)"
        }
    }
}

/// One cell of a query's results, as services return it: text, a number, true or false, a list of texts, or
/// something nested, kept as a marker.
public enum CellValue: Codable, Sendable {
    case text(String), number(Double), flag(Bool), list([String]), none, other

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .none }
        else if let flag = try? container.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let text = try? container.decode(String.self) { self = .text(text) }
        else if let list = try? container.decode([String].self) { self = .list(list) }
        else { self = .other }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        case .flag(let flag): try container.encode(flag)
        case .list(let list): try container.encode(list)
        case .none: try container.encodeNil()
        case .other: try container.encode("…")
        }
    }

    var shown: String {
        switch self {
        case .text(let text): text
        case .number(let number): number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .flag(let flag): String(flag)
        case .list(let list): list.joined(separator: ", ")
        case .none: ""
        case .other: "…"
        }
    }
}

/// A query's results: its columns and rows. The bot reads the first rows as a table; the structured result keeps
/// up to 100 rows, each keyed by column.
public struct ServiceTable: Sendable {
    public let columns: [String]
    public let rows: [[CellValue]]

    public init(columns: [String], rows: [[CellValue]]) { self.columns = columns; self.rows = rows }

    public func result() throws -> ServiceResult {
        struct Kept: Encodable { let columns: [String]; let rows: [[String: CellValue]]; let total: Int; let truncated: Bool }
        let kept = rows.prefix(100).map { row in
            Dictionary(zip(columns, row), uniquingKeysWith: { first, _ in first })
        }
        guard !rows.isEmpty else {
            return try ServiceResult(text: "The query returned no rows.", structured: Kept(columns: columns, rows: [], total: 0, truncated: false))
        }
        let shown = rows.prefix(20).map { $0.map(\.shown).joined(separator: " | ") }
        var text = "\(rows.count) row\(rows.count == 1 ? "" : "s")\(rows.count > kept.count ? ", first \(kept.count) kept" : ""):\n"
        text += columns.joined(separator: " | ") + "\n" + shown.joined(separator: "\n")
        if rows.count > shown.count { text += "\n… \(min(rows.count, 100) - shown.count) more rows in the structured result." }
        return try ServiceResult(text: text, structured: Kept(columns: columns, rows: kept, total: rows.count, truncated: rows.count > kept.count))
    }
}

/// An XML element, with its text and children, for the few services that still answer in XML.
public final class XMLNode: @unchecked Sendable {
    public let name: String
    public fileprivate(set) var text = ""
    public fileprivate(set) var children: [XMLNode] = []

    init(name: String) { self.name = name }

    /// The first child of that name.
    public func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    /// The text of the element found by following `path` down through children.
    public func value(_ path: String...) -> String? {
        var node: XMLNode? = self
        for name in path { node = node?.child(name) }
        let text = node?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
    /// Every element of that name at any depth below, in document order.
    public func all(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
    }

    static func parse(_ data: Data) -> XMLNode? {
        final class Reader: NSObject, XMLParserDelegate {
            let root = XMLNode(name: "")
            var stack: [XMLNode] = []
            override init() { super.init(); stack = [root] }
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                let node = XMLNode(name: name)
                stack.last?.children.append(node)
                stack.append(node)
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { stack.removeLast() }
        }
        let parser = XMLParser(data: data)
        let reader = Reader()
        parser.delegate = reader
        // Documents never reach out for entities they name.
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? reader.root.children.first : nil
    }
}

/// Checks for the values operations take, each refusing with a reason the bot can act on.
public enum ServiceInput {
    /// An IPv4 or IPv6 address, as given.
    public static func ip(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var v4 = in_addr(), v6 = in6_addr()
        guard inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1 else {
            throw ServiceError.input("\"\(value)\" is not an IPv4 or IPv6 address.")
        }
        return value
    }

    /// A domain name alone, lowercased.
    public static func domain(_ value: String) throws -> String {
        let field = ToolField(key: "domain", title: "the domain", placeholder: "example.com", kind: .host)
        guard let domain = try? field.validated(value) else {
            throw ServiceError.input("\"\(value)\" is not a domain name; give it alone, such as example.com.")
        }
        return domain
    }

    /// An email address: something before one @, and a domain after it.
    public static func email(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64, !parts[0].contains(where: { $0.isWhitespace || "/?#\\".contains($0) }),
              (try? domain(String(parts[1]))) != nil else {
            throw ServiceError.input("\"\(value)\" is not an email address.")
        }
        return value.lowercased()
    }

        /// A time in ISO 8601, such as 2026-11-13T00:00:00Z, as given.
    public static func time(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = ISO8601DateFormatter(), precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard plain.date(from: value) != nil || precise.date(from: value) != nil else {
            throw ServiceError.input("Give times in ISO 8601, such as 2026-11-13T00:00:00Z.")
        }
        return value
    }

    /// The moment `days` ago, in ISO 8601, for searches left open-ended.
    public static func daysAgo(_ days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 86_400))
    }

    /// One of `values`, or a reason naming them.
    public static func oneOf(_ value: String, _ values: [String], _ name: String) throws -> String {
        guard values.contains(value) else { throw ServiceError.input("\(name) is one of \(values.joined(separator: ", ")).") }
        return value
    }

    /// A value that goes inside quotes in a service's filter, refused when it holds a quote, backslash or line
    /// break that could end it early. `limit` is for values that run long, such as a full resource ID.
    public static func quoted(_ value: String, _ name: String, limit: Int = 200) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= limit, !value.contains(where: { $0 == "'" || $0 == "\"" || $0 == "\\" || $0.isNewline }) else {
            throw ServiceError.input("Give \(name) without quotes or backslashes.")
        }
        return value
    }

        /// A query in the service's own language: not empty, and short enough to send.
    public static func query(_ value: String, limit: Int = 10_000) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= limit else { throw ServiceError.input("Give a query of up to \(limit) characters.") }
        return value
    }

    /// A list of between one and `limit` values, each checked.
    public static func list(_ values: [String], limit: Int, _ each: (String) throws -> String) throws -> [String] {
        guard (1...limit).contains(values.count) else { throw ServiceError.input("Give between 1 and \(limit) values.") }
        return try values.map(each)
    }
}

/// A GraphQL request as services take it, and their answer: data, or errors saying why not.
private struct GraphQLRequest<Variables: Encodable>: Encodable { let query: String; let variables: Variables }
private struct GraphQLResponse<Answer: Decodable>: Decodable {
    struct Problem: Decodable { let message: String? }
    let data: Answer?
    let errors: [Problem]?
}

/// Requests to the connection's service, below its address: paths are built from separate parts, so no value
/// can climb out of the operation's own path, and every answer is checked before it is read.
public struct ServiceClient: Sendable {
    let base: URL
    let access: any ServiceAccess
    /// What the account filled in, such as its account ID.
    var settings: [String: String] = [:]
    /// Whether a refusal of the credentials is the service's own reason, for one that says plainly why it turned a
    /// request down, as AWS does for a service that is not enabled or a permission the role lacks, and that has no key
    /// to blame.
    var explainsRefusals = false
    /// The connection it reads for, for an operation that reads what the connection's trigger kept, such as what the
    /// watch found; nil where none is known.
    var account: UUID? = nil

    /// One of the account's details, by its field's key.
    public func setting(_ key: String) throws -> String {
        guard let value = settings[key], !value.isEmpty else { throw ServiceError.input("This connection has no \(key) set.") }
        return value
    }

    /// Runs a GraphQL query with its variables and returns its data. Errors the service reports come back as a refusal
    /// carrying their messages.
    public func graphQL<Answer: Decodable>(_ path: [String] = [], query: String, variables: some Encodable,
                                           as answer: Answer.Type = Answer.self) async throws -> Answer {
        let response = try await post(path, body: GraphQLRequest(query: query, variables: variables), as: GraphQLResponse<Answer>.self)
        if let errors = response.errors, !errors.isEmpty {
            throw ServiceError.refused(errors.compactMap(\.message).prefix(3).joined(separator: "; "))
        }
        guard let data = response.data else { throw ServiceError.unreadable }
        return data
    }

    /// `path`'s parts each go in as one segment; a part that would leave it is refused.
    /// `trailingSlash` ends the path with a slash, for services whose addresses do and redirect otherwise.
    /// `repeated` gives a parameter once for each of its values, for services that take a list that way.
    public func get<Answer: Decodable>(_ path: [String], query: [String: String?] = [:], repeated: [String: [String]] = [:],
                                       trailingSlash: Bool = false, as answer: Answer.Type = Answer.self) async throws -> Answer {
        try decode(Answer.self, try await exchange(path, query: query, repeated: repeated, trailingSlash: trailingSlash).data)
    }

    /// Sends `body` as JSON, for services that take a query or search that way. `headers` add to the request's
    /// own, such as the operation AWS reads from X-Amz-Target; `contentType` replaces the usual JSON one.
    public func post<Answer: Decodable>(_ path: [String], body: some Encodable, query: [String: String?] = [:],
                                        headers: [String: String] = [:], contentType: String = "application/json; charset=utf-8",
                                        as answer: Answer.Type = Answer.self) async throws -> Answer {
        try decode(Answer.self, try await data(path, query: query, method: "POST", body: try JSONEncoder().encode(body),
                                               contentType: contentType, headers: headers))
    }

    /// The same service at another host, for an account whose services each have their own, as AWS's do. The
    /// connection's access still decides which hosts may be reached.
    public func at(host: String) throws -> ServiceClient {
        guard let base = URL(string: "https://\(host)") else { throw ServiceError.input("\(host) is not a valid host.") }
        return ServiceClient(base: base, access: access, settings: settings, explainsRefusals: explainsRefusals, account: account)
    }

    /// Sends `form` URL-encoded, for services that take their parameters that way.
    public func postForm<Answer: Decodable>(_ path: [String], form: [String: String], as answer: Answer.Type = Answer.self) async throws -> Answer {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = form.sorted { $0.key < $1.key }.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return try decode(Answer.self, try await data(path, method: "POST", body: Data(body.utf8), contentType: "application/x-www-form-urlencoded"))
    }

    /// The body of an answer in XML, as older AWS APIs give it. It is asked for as XML: IAM and STS answer in JSON to
    /// a request that accepts it.
    public func xml(_ path: [String], query: [String: String?] = [:]) async throws -> XMLNode {
        guard let node = XMLNode.parse(try await data(path, query: query, headers: ["Accept": "text/xml"])) else { throw ServiceError.unreadable }
        return node
    }

    /// The answer in XML to a request whose parameters go URL-encoded in its body, as AWS's Query APIs take a change:
    /// a POST, which the transport never sends twice when the service could not answer it.
    public func xml(_ path: [String], form: [String: String]) async throws -> XMLNode {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = form.sorted { $0.key < $1.key }.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        guard let node = XMLNode.parse(try await data(path, method: "POST", body: Data(body.utf8), contentType: "application/x-www-form-urlencoded; charset=utf-8",
                                                      headers: ["Accept": "text/xml"])) else { throw ServiceError.unreadable }
        return node
    }

    /// What a service said when it refused, from the fields services put it in, on one short line. AWS's names its
    /// code too, such as AccessDenied, in JSON's __type or Code or in an XML Error, which S3 gives as the whole answer.
    static func reason(_ data: Data) -> String? {
        let code: String?, said: String?
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Google and Microsoft put it one level down, in error.message.
            said = ["detail", "message", "Message", "error_description", "error"].lazy.compactMap { object[$0] as? String }.first
                ?? (object["error"] as? [String: Any])?["message"] as? String
            // AWS's JSON APIs name the error in __type, sometimes after its namespace and a #.
            code = (object["__type"] as? String ?? object["Code"] as? String).map { String($0.split(separator: "#").last ?? "") }
        } else if let node = XMLNode.parse(data), let error = node.name == "Error" ? node : node.child("Error") ?? node.child("Errors")?.child("Error") {
            said = error.value("Message")
            code = error.value("Code")
        } else { return nil }
        let words = said?.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let line: String? = switch (code?.isEmpty == false ? code : nil, words?.isEmpty == false ? words : nil) {
        case let (code?, words?): words.hasPrefix(code) ? words : code + ": " + words
        case let (code?, nil): code
        case let (nil, words?): words
        case (nil, nil): nil
        }
        return line.map { String($0.prefix(300)) }
    }

    private func decode<Answer: Decodable>(_ type: Answer.Type, _ data: Data) throws -> Answer {
        do { return try JSONDecoder().decode(Answer.self, from: data) } catch { throw ServiceError.unreadable }
    }

    public func data(_ path: [String], query: [String: String?] = [:], method: String = "GET", body: Data? = nil,
                     contentType: String = "application/json; charset=utf-8", trailingSlash: Bool = false,
                     headers: [String: String] = [:]) async throws -> Data {
        try await exchange(path, query: query, method: method, body: body, contentType: contentType, trailingSlash: trailingSlash,
                           headers: headers).data
    }

    /// A request and its answer with the response, for an operation that needs its headers, such as a cookie that
    /// later requests of the same job must carry. An answer whose status is in `returning`, such as 412 for a
    /// condition not met, comes back for the operation to read rather than failing.
    public func exchange(_ path: [String], query: [String: String?] = [:], repeated: [String: [String]] = [:], method: String = "GET", body: Data? = nil,
                         contentType: String = "application/json; charset=utf-8", trailingSlash: Bool = false,
                         headers: [String: String] = [:], returning: Set<Int> = []) async throws -> (data: Data, response: HTTPURLResponse) {
        for part in path where part.isEmpty || part == "." || part == ".." || part.contains(where: { "/?#\\".contains($0) }) {
            throw ServiceError.input("\"\(part)\" is not a valid value here.")
        }
        let address = path.reduce(base) { $0.appendingPathComponent($1) }
        var components = URLComponents(url: trailingSlash ? address.appendingPathComponent("", isDirectory: true) : address,
                                       resolvingAgainstBaseURL: false)
        let items = (query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
            + repeated.flatMap { name, values in values.map { URLQueryItem(name: name, value: $0) } })
            .enumerated().sorted { ($0.element.name, $0.offset) < ($1.element.name, $1.offset) }.map(\.element)
        components?.queryItems = items.isEmpty ? nil : items
        // A plus sign in a value stays one: some services read a bare + in a query as a space.
        let encoded = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encoded
        guard let url = components?.url else { throw ServiceError.input("These values make no valid request.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await access.data(for: request)
        if returning.contains(response.statusCode) { return (data, response) }
        // Google says a quota ran out with a 403, which is no missing permission.
        if ToolConnectionAccess.isQuotaRefusal(response.statusCode, data) { throw ServiceError.rateLimited(Self.reason(data)) }
        // AWS says it throttled a request with a 400 or 503 naming the error, which the transport has already tried again.
        if explainsRefusals, ToolConnectionAccess.isAWSThrottle(response.statusCode, data) { throw ServiceError.rateLimited(Self.reason(data)) }
        if explainsRefusals, response.statusCode == 401 || response.statusCode == 403, let reason = Self.reason(data) {
            throw ServiceError.refused(reason)
        }
        switch response.statusCode {
        case 200..<300: return (data, response)
        case 401: throw ServiceError.rejected(Self.reason(data))
        case 403: throw ServiceError.forbidden(Self.reason(data))
        case 404: throw ServiceError.notFound
        case 429: throw ServiceError.rateLimited(Self.reason(data))
        // A request turned down for what it asked, or for the service's own state, with the service's reason.
        case 400, 409, 412, 422: throw Self.reason(data).map(ServiceError.refused) ?? ServiceError.status(response.statusCode)
        default: throw ServiceError.status(response.statusCode, Self.reason(data))
        }
    }
}

/// An adapter made of operations. Its tools are the operations' names and schemas; a call decodes the
/// operation's input and runs it. A failure the bot can act on comes back as an error result, not a fault.
public struct OperationAdapter: ToolConnectionAdapter {
    private struct Entry: Sendable {
        /// The tool as listed, in JSON.
        let tool: Data
        let run: @Sendable (Data, ServiceClient) async throws -> ServiceResult
    }
    private let entries: [(name: String, entry: Entry)]
    private let trigger: (any ServiceTrigger)?
    public let simultaneousRequests: Int?

    /// `simultaneousRequests` is for a service known to turn away a burst beyond that many requests from one connection.
    public init(operations: [any ServiceOperation], trigger: (any ServiceTrigger)? = nil, simultaneousRequests: Int? = nil) {
        entries = operations.map { Self.entry($0) }
        self.trigger = trigger
        self.simultaneousRequests = simultaneousRequests
    }

    /// The operation that reads what its trigger finds, if its service has a feed of new and serious things to watch;
    /// a lookup service has none.
    public var watchedTool: String? { trigger?.tool }
    public var alertLookBack: TimeInterval { trigger?.lookBack ?? AlertWatch.overlap }

    /// What the service raised from `since` on, as its trigger finds it, or nothing for an adapter without one.
    public func alerts(since: Date, connection: ToolConnection, access: ToolConnectionAccess) async throws -> [ServiceAlert] {
        try await alerts(since: since, connection: connection, access: access as any ServiceAccess)
    }

    func alerts(since: Date, connection: ToolConnection, access: any ServiceAccess) async throws -> [ServiceAlert] {
        guard let trigger else { return [] }
        return try await trigger.check(since: since, on: ServiceClient(base: connection.endpoint, access: access, settings: connection.settings ?? [:],
                                                                       account: connection.id),
                                       account: connection.id)
    }

    private static func entry<Operation: ServiceOperation>(_ operation: Operation) -> (name: String, entry: Entry) {
        let description: [String: Any] = [
            "name": Operation.name, "description": Operation.summary,
            "annotations": Operation.readOnly ? ["readOnlyHint": true] : ["readOnlyHint": false, "destructiveHint": Operation.destructive],
            "inputSchema": Operation.input.json,
        ]
        let tool = (try? JSONSerialization.data(withJSONObject: description, options: [.sortedKeys])) ?? Data("{}".utf8)
        return (Operation.name, Entry(tool: tool) { arguments, client in
            let input: Operation.Input
            do { input = try JSONDecoder().decode(Operation.Input.self, from: arguments) }
            catch { throw ServiceError.input(Self.reason(error)) }
            return try await operation.run(input, on: client)
        })
    }

    public func tools(for connection: ToolConnection) async throws -> Data {
        let tools = try entries.map { try JSONSerialization.jsonObject(with: $0.entry.tool) }
        return try JSONSerialization.data(withJSONObject: ["tools": tools], options: [.sortedKeys])
    }

    public func call(_ tool: String, arguments: Data, connection: ToolConnection, access: ToolConnectionAccess) async throws -> Data {
        try await run(tool, arguments: arguments, connection: connection, access: access)
    }

    /// A call through any access, so operations can be tried against a stand-in service.
    func run(_ tool: String, arguments: Data, connection: ToolConnection, access: any ServiceAccess) async throws -> Data {
        guard let entry = entries.first(where: { $0.name == tool })?.entry else {
            throw ToolConnectionError.message("This connection does not offer \(tool).")
        }
        do {
            let result = try await entry.run(arguments, ServiceClient(base: connection.endpoint, access: access, settings: connection.settings ?? [:],
                                                                      account: connection.id))
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
    public static let all: [String: any ToolConnectionAdapter] = ["virustotal": VirusTotal.adapter, "okta": Okta.adapter, "okta-containment": Okta.containmentAdapter, "shodan": Shodan.adapter,
                                                                  "entra": Entra.adapter, "entra-containment": Entra.containmentAdapter, "defender": Defender.adapter, "defender-containment": Defender.containmentAdapter,
                                                                  "crowdstrike": CrowdStrike.adapter, "crowdstrike-containment": CrowdStrike.containmentAdapter, "sentinelone": SentinelOne.adapter,
                                                                  "splunk": Splunk.adapter, "elastic": Elastic.adapter, "sentinel": Sentinel.adapter,
                                                                  "cloudflare": Cloudflare.adapter, "wiz": Wiz.adapter, "github": GitHub.adapter,
                                                                  "abuseipdb": AbuseIPDB.adapter, "urlscan": URLScan.adapter, "greynoise": GreyNoise.adapter, "crowdsec-cti": CrowdSec.adapter, "nvd": NVD.adapter, "crtsh": CrtSh.adapter, "dns": DNS.adapter,
                                                                  "otx": OTX.adapter, "haveibeenpwned": HaveIBeenPwned.adapter, "aws": AWS.adapter, "aws-containment": AWS.containmentAdapter,
                                                                  "google-cloud": GoogleCloud.adapter, "azure": Azure.adapter, "azure-containment": Azure.containmentAdapter,
                                                                  "google-cloud-containment": GoogleCloud.containmentAdapter,
                                                                  "google-workspace": GoogleWorkspace.adapter,
                                                                  "google-workspace-containment": GoogleWorkspace.containmentAdapter,
                                                                  "proofpoint": Proofpoint.adapter, "sumologic": SumoLogic.adapter,
                                                                  "tenable": Tenable.adapter, "censys": Censys.adapter, "grafana": Grafana.adapter, "sentry": Sentry.adapter]
}
