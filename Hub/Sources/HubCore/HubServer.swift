import Foundation
import Network
import NoodleCore

/// The Hub's API for paired clients: the conversations and messages bots already use
/// through the messenger, over HTTP on loopback. Every request needs the Hub's token.
public final class HubServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 47470
    /// Larger requests are refused; a message is text.
    static let requestLimit = 1 << 20

    private let repository: WorkspaceRepository
    private let token: Data
    private let queue = DispatchQueue(label: "com.pdparchitect.noodle.hub.server")
    private var listener: NWListener?

    public init(repository: WorkspaceRepository, token: String) {
        self.repository = repository
        self.token = Data("Bearer \(token)".utf8)
    }

    /// Listens on 127.0.0.1 only. Pass 0 for any free port. Returns the port in use.
    public func start(port: UInt16 = HubServer.defaultPort) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                      port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            // The listener reports state on this server's serial queue, so the flag needs no lock.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: listener.port?.rawValue ?? port)
                case .failed(let error):
                    once.done = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.requestLimit {
                self.send(connection, HubResponse(status: 413))
            } else if let request = HubRequest(parsing: buffer) {
                self.send(connection, self.respond(to: request))
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func send(_ connection: NWConnection, _ response: HubResponse) {
        connection.send(content: response.encoded, completion: .contentProcessed { _ in connection.cancel() })
    }

    func respond(to request: HubRequest) -> HubResponse {
        guard authorized(request.headers["authorization"]) else { return HubResponse(status: 401) }
        let parts = request.path.split(separator: "/").map(String.init)
        do {
            switch (request.method, parts.count) {
            case ("GET", 1) where parts[0] == "conversations":
                return try .json(repository.loadConversations())
            case (_, 3) where parts[0] == "conversations" && parts[2] == "messages":
                guard let id = UUID(uuidString: parts[1]),
                      try repository.loadConversations().contains(where: { $0.id == id }) else {
                    return HubResponse(status: 404)
                }
                switch request.method {
                case "GET":
                    let after = max(0, request.query["after"].flatMap(Int.init) ?? 0)
                    return try .json(Array(repository.loadMessages(conversationID: id).dropFirst(after)))
                case "POST":
                    guard let body = try? JSONDecoder().decode([String: String].self, from: request.body)["body"] else {
                        return HubResponse(status: 400)
                    }
                    return try .json(repository.sendUserMessage(conversationID: id, body: body), status: 201)
                default:
                    return HubResponse(status: 405)
                }
            default:
                return HubResponse(status: 404)
            }
        } catch WorkspaceError.emptyName {
            return HubResponse(status: 400)
        } catch WorkspaceError.missingConversation {
            return HubResponse(status: 404)
        } catch {
            return HubResponse(status: 500)
        }
    }

    /// Compares every byte so the time taken says nothing about the token.
    private func authorized(_ header: String?) -> Bool {
        let offered = Data((header ?? "").utf8)
        guard offered.count == token.count else { return false }
        return zip(offered, token).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct HubRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// Nil until the whole request, headers and body, has arrived.
    init?(parsing data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        let target = URLComponents(string: String(requestLine[1]))
        method = String(requestLine[0])
        path = target?.path ?? ""
        query = Dictionary((target?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        self.headers = headers
        self.body = Data(body.prefix(length))
    }
}

struct HubResponse {
    let status: Int
    var body = Data()

    static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> HubResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return HubResponse(status: status, body: try encoder.encode(value))
    }

    var encoded: Data {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// The secret a client presents with every request. Created once, readable by the Hub alone.
public enum HubAccessToken {
    public static let fileName = "hub-token"

    public static func load(root: URL) throws -> String {
        let file = root.appendingPathComponent(fileName)
        if let existing = try? String(contentsOf: file, encoding: .utf8), !existing.isEmpty { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return token
    }
}
