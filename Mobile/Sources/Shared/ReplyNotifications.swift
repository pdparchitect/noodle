import CloudKit
import Foundation
import HubLink
import os
import UserNotifications

/// The group the app shares with its notification and share extensions, named in each Info.plist.
enum AppGroup {
    static var identifier: String? { Bundle.main.object(forInfoDictionaryKey: "NoodleAppGroup") as? String }

    /// Where the Hubs this device joined are kept, so the extensions can reach them too.
    static var hubs: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }?
            .appendingPathComponent("Library/Application Support/Hubs", isDirectory: true)
    }
}

/// The conversation a notification is about, on the Hub whose topic it came under.
struct NotificationRoute: Equatable, Sendable {
    let topic: String
    let conversation: UUID
    /// Whether to call the bot once its conversation is open, as its widget's call button asks.
    var call = false
    /// A call a bot holds for the person, to show once its conversation is open, as its notification asks.
    var approval: UUID? = nil
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

    /// A notification from a Hub through CloudKit, or one the app posted itself with the same fields, as
    /// for a call it could not answer.
    static func route(userInfo: [AnyHashable: Any]) -> NotificationRoute? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let fields = notification.recordFields else {
            return route(fields: Dictionary(uniqueKeysWithValues: userInfo.compactMap { key, value in (key as? String).map { ($0, value) } }))
        }
        return route(fields: fields)
    }

    /// The Hub's word taken back, which CloudKit tells in silence, by the deleted record alone.
    static func withdrawal(userInfo: [AnyHashable: Any]) -> PushWithdrawal? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              notification.queryNotificationReason == .recordDeleted, let record = notification.recordID else { return nil }
        return withdrawal(subscriptionID: notification.subscriptionID, recordName: record.recordName)
    }

    static func withdrawal(subscriptionID: String?, recordName: String) -> PushWithdrawal? {
        guard let subscriptionID, subscriptionID.hasPrefix(withdrawalPrefix) else { return nil }
        let topic = String(subscriptionID.dropFirst(withdrawalPrefix.count))
        return topic.isEmpty ? nil : PushWithdrawal(topic: topic, recordName: recordName)
    }

    /// Starts the ID of the subscription that hears of a topic's word taken back; the topic follows.
    static let withdrawalPrefix = "read-"
}

/// Word of a conversation's unread replies, taken back by the Hub once they were read. The record's
/// name is all that is left of it, so it is matched against the conversations the phone knows.
struct PushWithdrawal: Equatable, Sendable {
    let topic: String
    let recordName: String

    func matches(_ route: NotificationRoute) -> Bool {
        route.topic == topic && LinkPush.recordName(topic: topic, conversation: route.conversation) == recordName
    }
}

/// What a notification of unread replies shows: the bot or group, and what was said last.
enum ReplyNotification {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NoodleMobile", category: "Notifications")

    struct Content: Equatable, Sendable {
        let title: String
        /// What was said, after the bot's name in a group.
        let body: String
        /// What was said alone, for a notification that shows who said it.
        let text: String
        /// The bot that said it.
        let sender: BotFace?
        let target: ShareTarget
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
        guard case .bots(let unpictured) = listed else { return nil }
        // Pictures as the app fetched them, which the bots list leaves out.
        let bots = pairing.keptPictures(unpictured), hubName = pairing.hub?.name ?? ""
        let target: ShareTarget
        if let bot = bots.first(where: { $0.conversationID == route.conversation }) {
            target = ShareTarget(bot: bot, hub: directory, hubName: hubName)
        } else if case .groups(let groups)? = try? await pairing.request(.groups), let group = groups.first(where: { $0.id == route.conversation }) {
            target = ShareTarget(group: group, members: group.draft.botIDs.compactMap { id in bots.first { $0.id == id } },
                                 hub: directory, hubName: hubName)
        } else {
            return nil
        }
        guard case .messages(let page)? = try? await pairing.request(.messagePage(LinkMessagePage(conversationID: route.conversation, limit: 10))),
              let reply = page.messages.last(where: { if case .bot = $0.author { true } else { false } }) else { return nil }
        let text = reply.body.isEmpty ? (reply.attachments.first?.filename ?? "Attachment") : MessageSegment.notificationText(reply.body)
        var speaker: LinkBot?
        if case .bot(let id) = reply.author { speaker = bots.first { $0.id == id } }
        let body = target.isGroup && speaker != nil ? "\(speaker!.draft.name): \(text)" : text
        return Content(title: target.name, body: body, text: text, sender: speaker.map(BotFace.init), target: target)
    }
}

/// A call a bot holds for the person, as a notification with Approve and Decline, whether the app posts it as it hears
/// from the Hub or the notification extension makes it from the Hub's ping. The Hub pings each held call under its own
/// ID where a reply's ping names its conversation, so the extension asks the Hub which it is.
enum HeldCallNotification {
    static let category = "approval"
    static let approveAction = "approve", declineAction = "decline"
    static let approvalKey = "approval", botKey = "bot"

    /// Exactly what will run, from the call itself, and the bot's reason. Tapping it opens the call in full.
    static func content(_ approval: LinkApproval, botID: UUID, botName: String, topic: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = botName
        content.subtitle = "Asks to run \(approval.tool) on \(approval.providerTitle)"
        let input = approval.inputLines.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        content.body = MessageSegment.notificationText([input, approval.reason].filter { !$0.isEmpty }.joined(separator: "\n"))
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = approval.conversationID.uuidString
        content.userInfo = [LinkPush.topicField: topic, LinkPush.conversationField: approval.conversationID.uuidString,
                            approvalKey: approval.id.uuidString, botKey: botID.uuidString]
        return content
    }

    /// The held call a Hub's ping names, and its bot; nil when the ping is a reply's, or the Hub cannot be reached.
    @MainActor static func held(for route: NotificationRoute, hubs: URL) async -> (approval: LinkApproval, bot: LinkBot)? {
        guard let directory = PushTopic.directory(of: route.topic, in: hubs),
              case .bots(let bots)? = try? await HubPairing(directory: directory, deviceName: "").request(.bots) else { return nil }
        for bot in bots where bot.owner == nil {
            if let approval = bot.approvals.first(where: { $0.id == route.conversation }) { return (approval, bot) }
        }
        return nil
    }

    /// The held call whose ping the Hub took back, once decided on any device: no longer pending here. Nil when the
    /// ping was a reply's.
    static func withdrawn(_ withdrawal: PushWithdrawal, hubs: URL) -> UUID? {
        guard let directory = PushTopic.directory(of: withdrawal.topic, in: hubs) else { return nil }
        let pending = AppBadge.pendingApprovals(in: directory)
        guard let id = pending.first(where: { LinkPush.recordName(topic: withdrawal.topic, conversation: $0) == withdrawal.recordName }) else {
            return nil
        }
        AppBadge.setPendingApprovals(pending.subtracting([id]), in: directory)
        return id
    }

    /// Takes away the notifications of calls no longer held, whichever way they came.
    static func remove(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let shown = await center.deliveredNotifications().filter { notification in
            (notification.request.content.userInfo[approvalKey] as? String).flatMap(UUID.init(uuidString:)).map(ids.contains) ?? false
        }
        center.removeDeliveredNotifications(withIdentifiers: shown.map(\.request.identifier) + ids.map(LinkApproval.notificationIdentifier))
    }
}
