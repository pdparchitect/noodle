import CloudKit
import Foundation
import HubLink
import os

/// The group the app shares with its notification extension, named in both Info.plists.
enum AppGroup {
    static var identifier: String? { Bundle.main.object(forInfoDictionaryKey: "NoodleAppGroup") as? String }

    /// Where the Hubs this device joined are kept, so the notification extension can reach them too.
    static var hubs: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }?
            .appendingPathComponent("Library/Application Support/Hubs", isDirectory: true)
    }
}

/// The conversation a notification is about, on the Hub whose topic it came under.
struct NotificationRoute: Equatable, Sendable {
    let topic: String
    let conversation: UUID
}

/// What the phone gave each Hub to leave word of unread replies under.
enum PushTopic {
    /// Random and kept in the Hub's folder, so only that Hub and this phone know it, and it goes when
    /// the phone leaves the Hub.
    static func topic(for directory: URL) -> String {
        let url = directory.appendingPathComponent("push-topic")
        if let topic = try? String(contentsOf: url, encoding: .utf8), !topic.isEmpty { return topic }
        let topic = UUID().uuidString.lowercased()
        try? topic.write(to: url, atomically: true, encoding: .utf8)
        return topic
    }

    @MainActor static func topic(for pairing: HubPairing) -> String { topic(for: pairing.directory) }

    /// The Hub folder whose topic this is, if the phone still has it.
    static func directory(of topic: String, in hubs: URL) -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: hubs, includingPropertiesForKeys: nil)) ?? []
        return folders.first { (try? String(contentsOf: $0.appendingPathComponent("push-topic"), encoding: .utf8)) == topic }
    }

    static func route(fields: [String: Any]) -> NotificationRoute? {
        guard let topic = fields[LinkPush.topicField] as? String,
              let conversation = (fields[LinkPush.conversationField] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return NotificationRoute(topic: topic, conversation: conversation)
    }

    static func route(userInfo: [AnyHashable: Any]) -> NotificationRoute? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let fields = notification.recordFields else { return nil }
        return route(fields: fields)
    }
}

/// What a notification of unread replies shows: the bot, and what it said last.
enum ReplyNotification {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NoodleMobile", category: "Notifications")

    struct Content: Equatable, Sendable {
        let title: String
        let body: String
    }

    /// Asks the Hub the notification came from; nil when the phone no longer has that Hub or it cannot be reached.
    @MainActor static func content(for route: NotificationRoute, hubs: URL) async -> Content? {
        guard let directory = PushTopic.directory(of: route.topic, in: hubs) else { return nil }
        let pairing = HubPairing(directory: directory, deviceName: "")
        let listed: LinkResponse
        do { listed = try await pairing.request(.bots) } catch {
            log.error("The Hub could not be reached for a notification's reply: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard case .bots(let bots) = listed,
              let bot = bots.first(where: { $0.conversationID == route.conversation }),
              case .messages(let page)? = try? await pairing.request(.messagePage(LinkMessagePage(conversationID: route.conversation, limit: 10))),
              let reply = page.messages.last(where: { if case .bot = $0.author { true } else { false } }) else { return nil }
        let body = reply.body.isEmpty ? (reply.attachments.first?.filename ?? "Attachment") : MessageSegment.previewText(reply.body)
        return Content(title: bot.draft.name, body: body)
    }
}
