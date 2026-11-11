import Foundation
import HubLink
import Observation

/// Every Hub this terminal joined, and the bots and groups of them all in one list, as the phone's All shows them.
@MainActor @Observable public final class TerminalHubs {
    /// A bot or group of one Hub, as a row of the list.
    public struct Row: Identifiable, Equatable {
        public let chats: HubChats
        public let thread: HubThread
        public var id: Key { Key(hub: chats.id, thread: thread.id) }

        public init(chats: HubChats, thread: HubThread) {
            self.chats = chats
            self.thread = thread
        }

        public struct Key: Hashable, Sendable {
            public let hub: ObjectIdentifier
            public let thread: UUID
        }

        public static func == (lhs: Row, rhs: Row) -> Bool { lhs.chats === rhs.chats && lhs.thread == rhs.thread }
    }

    /// A message that says what was searched for, with the Hub and bot or group it is in.
    public struct MessageMatch: Identifiable, Equatable {
        public let row: Row
        public let match: LinkMessageMatch
        public var id: UUID { match.messageID }
    }

    /// What the list shows: every Hub's bots and groups, or one Hub's.
    public enum Space: Hashable, Sendable {
        case all
        case hub(ObjectIdentifier)
    }

    public let memberships: HubMemberships
    public private(set) var chats: [HubChats] = []
    /// Back to All when its Hub is left.
    public var space: Space = .all
    @ObservationIgnored private var following: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(directory: URL, deviceName: String) {
        memberships = HubMemberships(directory: directory, deviceName: deviceName)
        syncChats()
    }

    /// Where this terminal keeps each Hub's folder and key, readable only by this user.
    public static var standardDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Noodle Terminal/Hubs", isDirectory: true)
        #else
        // Where Linux keeps an app's own data.
        (ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true))
            .appendingPathComponent("noodle-terminal/Hubs", isDirectory: true)
        #endif
    }

    /// What the Hub lists this terminal as among the person's devices.
    public static var standardDeviceName: String {
        #if os(macOS)
        let computer = Host.current().localizedName ?? "Mac"
        #else
        let computer = ProcessInfo.processInfo.hostName
        #endif
        return "\(computer) Terminal"
    }

    /// Joins the Hub an invitation link or code names, and starts following it.
    public func join(_ invitationText: String) async {
        await memberships.join(invitationText)
        syncChats()
    }

    /// Checks in with every Hub and follows each one's changes until cancelled.
    public func run() async {
        isRunning = true
        defer {
            isRunning = false
            following.values.forEach { $0.cancel() }
            following = [:]
        }
        syncChats()
        await memberships.stayConnected()
    }

    @ObservationIgnored private var isRunning = false

    /// A chats for each Hub joined, each followed while `run` runs.
    private func syncChats() {
        let kept = chats
        chats = memberships.hubs.map { pairing in kept.first { $0.pairing === pairing } ?? HubChats(pairing: pairing) }
        for gone in kept where !chats.contains(where: { $0 === gone }) { following.removeValue(forKey: gone.id)?.cancel() }
        guard isRunning else { return }
        for chats in chats where following[chats.id] == nil {
            following[chats.id] = Task { await chats.follow() }
        }
    }

    public var isLoaded: Bool { chats.contains { $0.isLoaded } }

    /// The Hubs the space shows.
    public var shownChats: [HubChats] {
        switch space {
        case .all: chats
        case .hub(let id): chats.filter { $0.id == id }
        }
    }

    public func name(of space: Space) -> String {
        switch space {
        case .all: "All"
        case .hub(let id): chats.first { $0.id == id }?.hubName ?? "All"
        }
    }

    /// All first, then each Hub.
    public var spaces: [Space] { [.all] + chats.map { .hub($0.id) } }

    /// Pinned first, in the order they were pinned, then the newest conversation first, across the space's Hubs.
    /// Pins are the Hub's, so they are the same on every device.
    public var rows: [Row] {
        shownChats.flatMap { chats in chats.listedThreads.map { Row(chats: chats, thread: $0) } }
            .sorted(by: Self.isOrderedBefore)
    }

    /// Leaves the Hub at once and tells it, now or at a later check-in. Its key goes once the Hub has heard.
    public func leave(_ chats: HubChats) {
        memberships.leave(chats.pairing)
        if case .hub(chats.id) = space { space = .all }
        syncChats()
    }

    static func isOrderedBefore(_ lhs: Row, _ rhs: Row) -> Bool {
        switch (lhs.thread.pinnedAt, rhs.thread.pinnedAt) {
        case (let left?, let right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.chats.recency(of: lhs.thread) > rhs.chats.recency(of: rhs.thread)
        }
    }

    public func row(_ key: Row.Key?) -> Row? {
        guard let key, let chats = chats.first(where: { $0.id == key.hub }), let thread = chats.thread(key.thread) else { return nil }
        return Row(chats: chats, thread: thread)
    }

    /// The bots and groups the search finds, bots first, by name before description, as on the Mac and phone.
    public func rows(matching search: ConversationSearch) -> [Row] {
        let rows = rows
        let sections = search.sections(rows.map { $0.chats.searchCandidate($0.thread, id: $0.id) })
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (sections.bots + sections.groups).compactMap { byID[$0] }
    }

    /// Each message on every Hub that says the term, newest first. A Hub that cannot search is left out.
    public func messages(matching search: ConversationSearch) async -> [MessageMatch] {
        var found: [MessageMatch] = []
        for chats in shownChats {
            guard let matches = try? await chats.searchMessages(search) else { continue }
            for match in matches {
                guard let thread = chats.listedThreads.first(where: { $0.conversationID == match.conversationID }) else { continue }
                found.append(MessageMatch(row: Row(chats: chats, thread: thread), match: match))
            }
        }
        return found.sorted { $0.match.createdAt > $1.match.createdAt }
    }
}
