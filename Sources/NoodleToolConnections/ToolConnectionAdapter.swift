import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NoodleCore

/// Answers for the connections an app serves itself rather than through an MCP server: the app's own code
/// calling a service's API. Results are shaped as MCP's, so bots use them as they use any other connection.
public protocol ToolConnectionAdapter: Sendable {
    /// The tools, as an MCP tools/list result.
    func tools(for connection: ToolConnection) async throws -> Data
    /// One call with its JSON arguments, as an MCP tools/call result. `access` reaches the service with the
    /// connection's credentials.
    func call(_ tool: String, arguments: Data, connection: ToolConnection, access: ToolConnectionAccess) async throws -> Data
    /// The tool that reads in full what `alerts` finds, for an adapter whose service has a feed of new and serious things,
    /// which the app then watches for every connection it serves; nil for one without, such as a lookup service.
    var watchedTool: String? { get }
    /// What the service raised from `since` on, at most `ServiceAlert.most` of it, newest first.
    func alerts(since: Date, connection: ToolConnection, access: ToolConnectionAccess) async throws -> [ServiceAlert]
    /// How far each check for alerts reads back from the newest one seen, as the service lists some after their time.
    var alertLookBack: TimeInterval { get }
    /// How many requests the service takes at once from one connection, for a service known to refuse a burst
    /// beyond that; nil for no limit. The rest wait their turn.
    var simultaneousRequests: Int? { get }
}

public extension ToolConnectionAdapter {
    var watchedTool: String? { nil }
    var simultaneousRequests: Int? { nil }
    var alertLookBack: TimeInterval { AlertWatch.overlap }
    func alerts(since: Date, connection: ToolConnection, access: ToolConnectionAccess) async throws -> [ServiceAlert] { [] }
}

/// How an adapter reaches its service: only the connection's own host, over its own scheme (HTTPS, or HTTP for a
/// service on this Mac or the local network), with the connection's credentials added and never shown to it. Redirects are not followed, so they cannot carry the credentials away.
public struct ToolConnectionAccess: Sendable {
    let endpoint: URL
    let authorization: ConnectionAuthorization?
    /// The connection's share of its service, for a service that takes only so many requests at once.
    let gate: RequestGate?
    /// Waits the given seconds before a request is tried again.
    let pause: @Sendable (Double) async throws -> Void
    let configuration: @Sendable () -> URLSessionConfiguration
    static let limit = 8 * 1_048_576

    init(endpoint: URL, authorization: ConnectionAuthorization?, gate: RequestGate? = nil,
         pause: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         configuration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.endpoint = endpoint; self.authorization = authorization; self.gate = gate; self.pause = pause; self.configuration = configuration
    }
    private func url(_ request: URLRequest) -> URL? { request.url }

    /// For an AWS connection signed in through IAM Identity Center: every account its sign-in covers.
    public func awsAccounts() async throws -> [AWSAccount] {
        guard case .awsOrganisation(let organisation)? = authorization else { throw Self.notIdentityCenter }
        return try await organisation.accounts()
    }

    /// The same access, signing as the connection's role in one of the accounts its sign-in covers.
    public func awsAccount(_ id: String) async throws -> ToolConnectionAccess {
        guard case .awsOrganisation(let organisation)? = authorization else { throw Self.notIdentityCenter }
        return ToolConnectionAccess(endpoint: endpoint, authorization: .aws(try await organisation.keys(id), defaultRegion: organisation.region),
                                    gate: gate, pause: pause, configuration: configuration)
    }

    private static let notIdentityCenter = ToolConnectionError.message("This connection does not sign in through AWS IAM Identity Center.")

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // An organisation's sign-in signs nothing itself: each request goes as one account's role.
        if case .awsOrganisation? = authorization { throw ToolConnectionError.message("Name the AWS account the request is for.") }
        // Only the connection's host; an AWS connection, any AWS service below it, since each request is signed for one.
        let host = url(request)?.host?.lowercased() ?? "", home = endpoint.host?.lowercased() ?? ""
        let reachable = host == home || (authorization?.coversSubdomains == true && host.hasSuffix("." + home))
        guard let url = request.url, url.scheme?.lowercased() == endpoint.scheme?.lowercased(), reachable, url.port == endpoint.port, url.user == nil else {
            throw ToolConnectionError.message("A tool adapter may only reach its own service.")
        }
        var request = request
        authorization?.apply(to: &request)
        // A service that turned the request away for now gets it again after a pause, as long as a bot would wait.
        var attempt = 1, waited = 0.0
        while true {
            let (data, response) = try await send(request)
            guard attempt < Self.attempts, let pause = Self.pause(after: response, data, method: request.httpMethod, attempt: attempt),
                  waited + pause <= Self.patience else { return (data, response) }
            attempt += 1
            waited += pause
            try await self.pause(pause)
            Retries.counting?.add()
        }
    }

    static let attempts = 4, patience = 30.0

    /// How long to wait before sending a request again, or nil when it should not be: only when the service was rate
    /// limiting, or could not answer a read. A write it could not answer may still have been done, so it never goes twice.
    static func pause(after response: HTTPURLResponse, _ data: Data, method: String?, attempt: Int) -> Double? {
        let read = ["GET", "HEAD"].contains(method?.uppercased() ?? "GET")
        guard response.statusCode == 429 || (response.statusCode == 503 && read) || isQuotaRefusal(response.statusCode, data) else { return nil }
        if let asked = response.value(forHTTPHeaderField: "Retry-After").flatMap(retryAfter) { return asked }
        return Double(1 << (attempt - 1)) * Double.random(in: 0.5...1)
    }

    /// Retry-After in seconds, or as an HTTP date.
    private static func retryAfter(_ value: String) -> Double? {
        if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) { return seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    /// Whether a 403 is a quota or rate limit rather than missing permission, as Google says it, in the reason of
    /// its JSON error or its status.
    public static func isQuotaRefusal(_ status: Int, _ data: Data) -> Bool {
        guard status == 403, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return false }
        if error["status"] as? String == "RESOURCE_EXHAUSTED" { return true }
        let reasons = ((error["errors"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
            + ((error["details"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
        return reasons.contains { ["rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded", "RATE_LIMIT_EXCEEDED"].contains($0) }
    }

    /// One try, in turn with the connection's other requests when its service takes only so many at once.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await gate?.enter()
        do {
            let answer = try await reach(request)
            await gate?.leave()
            return answer
        } catch {
            await gate?.leave()
            throw error
        }
    }

    private func reach(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // The guard on MCP traffic takes only public HTTPS and turns every answer but a success into an error. An adapter
        // checks its own requests above, and reads the service's status to say what went wrong, so it goes without it.
        let configuration = configuration()
        configuration.protocolClasses = configuration.protocolClasses?.filter { $0 != MCPGuardedHTTP.self }
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request, limit: Self.limit, tooLarge: ToolConnectionServiceError.responseTooLarge)
        guard let http = response as? HTTPURLResponse else { throw ToolConnectionServiceError.network(0) }
        return (data, http)
    }
}

/// Lets at most `limit` requests through at once; the rest wait their turn, in the order they came.
actor RequestGate {
    private let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, turn: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) { self.limit = max(1, limit) }

    /// How many requests are waiting their turn.
    var queued: Int { waiting.count }

    /// Waits for a place, giving up its turn if cancelled meanwhile.
    func enter() async throws {
        guard running >= limit else { running += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (turn: CheckedContinuation<Void, Error>) -> Void in
                if Task.isCancelled { turn.resume(throwing: CancellationError()) } else { waiting.append((id: id, turn: turn)) }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    private func abandon(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).turn.resume(throwing: CancellationError())
    }

    /// Hands the place to the longest waiting request, if any.
    func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().turn.resume() }
    }
}

/// The requests a bot's call or an alert check sent again, after its service rate limited them or could not answer,
/// so its line in the tool's activity can say so.
public final class Retries: @unchecked Sendable {
    /// The count for whatever this task, and the tasks it starts, send.
    @TaskLocal public static var counting: Retries?
    private let lock = NSLock()
    private var count = 0

    public init() {}
    public var total: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }

    /// What a line of activity adds for them: nothing when there were none.
    public var shown: String { Self.shown(total) }

    static func shown(_ count: Int) -> String {
        switch count {
        case ...0: ""
        case 1: "1 request retried"
        default: "\(count) requests retried"
        }
    }
}

/// An AWS account a connection signed in through IAM Identity Center may use.
public struct AWSAccount: Equatable, Sendable {
    public let id: String
    public let name: String
    public let email: String?
    public init(id: String, name: String, email: String?) { self.id = id; self.name = name; self.email = email }
}

/// What an AWS connection signed in through Identity Center reaches: the accounts its sign-in covers, and keys for the
/// connection's role in one of them, got when first asked for.
struct AWSOrganisation: Sendable {
    /// Where requests go unless they name another region.
    let region: String
    let accounts: @Sendable () async throws -> [AWSAccount]
    let keys: @Sendable (String) async throws -> ConnectionAWSKey
}

/// How a request proves who its connection is: a header, or for a service that takes its key only there, a
/// parameter in its address.
enum ConnectionAuthorization: Sendable {
    case header(String, String)
    case parameter(String, String)
    /// Signed with one account's AWS keys, for the service and region each request's address names.
    case aws(ConnectionAWSKey, defaultRegion: String)
    /// An organisation's Identity Center sign-in, which signs as one of its accounts once the adapter names it.
    case awsOrganisation(AWSOrganisation)
    /// A Google access token, good for every googleapis.com service its scopes allow.
    case google(String)

    /// Whether it reaches every service below its connection's host, as an AWS key or a Google token does.
    var coversSubdomains: Bool {
        switch self {
        case .aws, .awsOrganisation, .google: true
        case .header, .parameter: false
        }
    }

    func apply(to request: inout URLRequest) {
        switch self {
        case .header(let name, let value):
            request.setValue(value, forHTTPHeaderField: name)
        case .google(let token):
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        case .parameter(let name, let value):
            guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            components.queryItems = (components.queryItems ?? []).filter { $0.name != name } + [URLQueryItem(name: name, value: value)]
            // A token may hold characters a query keeps as they are, such as + and /.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F")
            request.url = components.url ?? url
        case .aws(let key, let defaultRegion):
            guard let host = request.url?.host, let scope = AWSSignature.scope(of: host, defaultRegion: defaultRegion) else { return }
            AWSSignature.sign(&request, key: key, region: scope.region, service: scope.service)
        case .awsOrganisation:
            break
        }
    }
}
