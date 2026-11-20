import Foundation

public enum ContextFieldKind: String, Sendable, Equatable {
    case text, checkbox, radio, choice, date, other
}

/// One control captured from another app's window. Toggles hold "true" or "false".
public struct ContextField: Sendable, Equatable {
    public var id: String
    public var label: String?
    public var kind: ContextFieldKind
    public var value: String?
    /// A choice's options, as the control lists them.
    public var options: [String]
    public init(id: String, label: String?, kind: ContextFieldKind, value: String?, options: [String] = []) {
        self.id = id; self.label = label; self.kind = kind; self.value = value; self.options = options
    }
}

/// The live controls behind a capture. Noodle implements this with Accessibility; tests use their own.
/// Nothing here reports success: the provider reads every field back to see what took.
public protocol ContextFieldSurface: AnyObject, Sendable {
    /// Nil once the field or its app is gone.
    func value(of field: String) async -> String?
    func setText(_ text: String, of field: String) async
    func press(_ field: String) async
    func choose(_ option: String, in field: String) async
}

public struct ContextFieldCapture: Sendable {
    public var app: String
    public var window: String?
    public var page: String?
    public var fields: [ContextField]
    /// Labels of the fields left out as sensitive, so the bot can say why it did not fill them.
    public var withheld: [String]
    public var surface: any ContextFieldSurface
    public init(app: String, window: String?, page: String?, fields: [ContextField], withheld: [String] = [],
                surface: any ContextFieldSurface) {
        self.app = app; self.window = window; self.page = page; self.fields = fields; self.withheld = withheld; self.surface = surface
    }
}

/// Which bot may fill which captured fields, and until when. A capture waits with its attachment
/// until that is sent; then each bot it went to gets its own token for `lifetime`. Kept in memory
/// only, so quitting Noodle ends every token.
public final class ContextFieldGrants: @unchecked Sendable {
    public static let lifetime: TimeInterval = 15 * 60

    public struct Grant: Sendable {
        public let token: String
        public let expires: Date
        let captureID: UUID
        public let capture: ContextFieldCapture
    }

    /// Per field, what Noodle accounts for: the captured value, or what it wrote since.
    private struct Held { var capture: ContextFieldCapture; var values: [String: Set<String>] }
    private struct Token { let captureID: UUID; let agent: UUID; let expires: Date }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let newToken: @Sendable () -> String
    private var held: [UUID: Held] = [:]
    private var staged: [UUID: (captureID: UUID, until: Date)] = [:]
    private var tokens: [String: Token] = [:]

    public init(now: @escaping @Sendable () -> Date = Date.init,
                token: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.now = now; self.newToken = token
    }

    /// Context waiting in a message field. Left unsent for `lifetime`, it is dropped.
    public func stage(_ capture: ContextFieldCapture, attachment: UUID) {
        lock.withLock {
            prune()
            let id = UUID()
            held[id] = Held(capture: capture, values: Dictionary(capture.fields.map { ($0.id, [$0.value ?? ""]) }) { $1 })
            staged[attachment] = (id, now().addingTimeInterval(Self.lifetime))
        }
    }

    /// The attachments were sent to these bots: each gets its own token. A capture is granted once,
    /// so sending the same attachment on later grants nothing.
    public func grant(attachments: [UUID], to agents: [UUID]) {
        lock.withLock {
            prune()
            let expires = now().addingTimeInterval(Self.lifetime)
            for attachment in attachments {
                guard let captureID = staged.removeValue(forKey: attachment)?.captureID else { continue }
                for agent in Set(agents) { tokens[newToken()] = Token(captureID: captureID, agent: agent, expires: expires) }
            }
            prune()
        }
    }

    public func grants(for agent: UUID) -> [Grant] {
        lock.withLock {
            prune()
            return tokens.filter { $0.value.agent == agent }
                .compactMap { token, entry in held[entry.captureID].map { Grant(token: token, expires: entry.expires, captureID: entry.captureID, capture: $0.capture) } }
                .sorted { $0.expires > $1.expires }
        }
    }

    /// Nil for a token that expired or belongs to another bot, without saying which.
    public func grant(_ token: String, for agent: UUID) -> Grant? {
        lock.withLock {
            prune()
            guard let entry = tokens[token], entry.agent == agent, let capture = held[entry.captureID]?.capture else { return nil }
            return Grant(token: token, expires: entry.expires, captureID: entry.captureID, capture: capture)
        }
    }

    /// What the field held when captured, or what Noodle wrote there since: anything else is the person's.
    /// A write not yet shown leaves two, since either may be what the field holds next.
    func expected(_ field: String, in grant: Grant) -> Set<String> { lock.withLock { held[grant.captureID]?.values[field] ?? [] } }

    func record(_ values: Set<String>, for field: String, in grant: Grant) { lock.withLock { held[grant.captureID]?.values[field] = values } }

    private func prune() {
        let now = now()
        tokens = tokens.filter { $0.value.expires > now }
        staged = staged.filter { $0.value.until > now }
        let live = Set(tokens.values.map(\.captureID)).union(staged.values.map(\.captureID))
        held = held.filter { live.contains($0.key) }
    }
}
