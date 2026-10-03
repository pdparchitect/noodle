import Foundation
import Observation

/// Something done to the Hub's users or devices, or tried and refused.
public struct HubActivityEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    /// Who did it: "This Mac" for the Hub's own Settings, otherwise the user and their device.
    public var who: String
    /// What they did or tried, with names as they were then, since users and devices come and go.
    public var what: String
    /// Why the Hub refused, when it did.
    public var refusal: String?
    /// The users it concerns, whoever acted included.
    public var users: Set<UUID>
}

/// Who the changes being made are made by.
public struct HubActor: Sendable {
    public var who: String
    public var user: UUID?

    public init(who: String, user: UUID?) {
        self.who = who
        self.user = user
    }

    public static let thisMac = HubActor(who: "This Mac", user: nil)
}

/// The Activity window's record, kept for 90 days. Appended a line at a time, so a busy Hub
/// rewrites the file only when old entries go. Refusals are capped, and push out only older
/// refusals: a device flooding the Hub cannot push out the record of a change.
@MainActor @Observable public final class HubActivityLog {
    public static let retention: TimeInterval = 90 * 24 * 60 * 60
    /// The most refusals kept, however many refused requests a device sends.
    public let limit: Int

    /// Oldest first.
    public private(set) var entries: [HubActivityEntry] = []
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let now: () -> Date

    public init(url: URL, now: @escaping () -> Date = Date.init, limit: Int = 10_000) {
        self.url = url
        self.now = now
        self.limit = limit
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n") ?? []
        entries = lines.compactMap { try? Self.decoder.decode(HubActivityEntry.self, from: Data($0.utf8)) }
        if trim() || entries.count != lines.count { rewrite() }
    }

    public func record(who: String, what: String, refusal: String? = nil, users: Set<UUID>) {
        let entry = HubActivityEntry(id: UUID(), date: now(), who: who, what: what, refusal: refusal, users: users)
        entries.append(entry)
        if trim() {
            rewrite()
        } else if let line = try? Self.encoder.encode(entry) {
            append(line + Data("\n".utf8))
        }
    }

    /// Oldest first; every entry when `user` is nil.
    public func entries(about user: UUID?) -> [HubActivityEntry] {
        guard let user else { return entries }
        return entries.filter { $0.users.contains(user) }
    }

    /// Drops what is too old or too many; true when anything went.
    private func trim() -> Bool {
        let cutoff = now().addingTimeInterval(-Self.retention)
        let count = entries.count
        entries.removeAll { $0.date < cutoff }
        var excess = entries.count { $0.refusal != nil } - limit
        if excess > 0 {
            entries.removeAll { entry in
                guard excess > 0, entry.refusal != nil else { return false }
                excess -= 1
                return true
            }
        }
        return entries.count != count
    }

    private func append(_ data: Data) {
        guard let handle = try? FileHandle(forWritingTo: url) else {
            rewrite()
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func rewrite() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = entries.compactMap { try? Self.encoder.encode($0) }
        try? Data(lines.map { $0 + Data("\n".utf8) }.joined()).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
