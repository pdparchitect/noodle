import Foundation
import UserNotifications

/// The number on the app's icon: how many conversations have replies not read yet, and how many calls bots hold
/// for the person's approval, on every Hub the phone joined. Each Hub's folder keeps those conversations, written by the app from what the Hub
/// told it and by the notification extension as word of a reply comes, so the number stays right
/// while the app is closed. A conversation read on another device leaves it when the Hub takes its
/// word back.
enum AppBadge {
    static let fileName = "unread.json"
    /// The calls held for the person, as the app last heard from the Hub.
    static let approvalsFileName = "approvals.json"

    static func pendingApprovals(in directory: URL) -> Set<UUID> {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(approvalsFileName)),
              let pending = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(pending)
    }

    static func setPendingApprovals(_ pending: Set<UUID>, in directory: URL) {
        guard pending != pendingApprovals(in: directory) else { return }
        let sorted = pending.map(\.uuidString).sorted().compactMap(UUID.init(uuidString:))
        try? JSONEncoder().encode(sorted).write(to: directory.appendingPathComponent(approvalsFileName), options: .atomic)
    }

    static func unread(in directory: URL) -> Set<UUID> {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let unread = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(unread)
    }

    static func setUnread(_ unread: Set<UUID>, in directory: URL) {
        guard unread != self.unread(in: directory) else { return }
        let sorted = unread.map(\.uuidString).sorted().compactMap(UUID.init(uuidString:))
        try? JSONEncoder().encode(sorted).write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    /// Conversations waiting unread on the Hubs kept in this folder. A Hub being left keeps its
    /// folder until it has heard, but no longer counts.
    static func count(hubs: URL) -> Int {
        let folders = (try? FileManager.default.contentsOfDirectory(at: hubs, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("hub.json").path) }
            .reduce(0) { $0 + unread(in: $1).count + pendingApprovals(in: $1).count }
    }

    /// Word of a reply came: its conversation waits unread. The icon's new number, or nil when the
    /// phone no longer has that Hub.
    static func arrived(_ route: NotificationRoute, hubs: URL) -> Int? {
        guard let directory = PushTopic.directory(of: route.topic, in: hubs) else { return nil }
        setUnread(unread(in: directory).union([route.conversation]), in: directory)
        return count(hubs: hubs)
    }

    /// The Hub took back its word of a conversation, as it does once it is read on any device.
    /// Whether the icon's number changed.
    static func withdrawn(_ withdrawal: PushWithdrawal, hubs: URL) -> Bool {
        guard let directory = PushTopic.directory(of: withdrawal.topic, in: hubs) else { return false }
        let waiting = unread(in: directory)
        let read = waiting.filter { withdrawal.matches(NotificationRoute(topic: withdrawal.topic, conversation: $0)) }
        guard !read.isEmpty else { return false }
        setUnread(waiting.subtracting(read), in: directory)
        return true
    }

    /// Read on this phone.
    static func read(_ conversation: UUID, in directory: URL) {
        setUnread(unread(in: directory).subtracting([conversation]), in: directory)
    }

    static func show(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
