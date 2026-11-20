import AppKit
import Foundation
import HubLink
import NoodleCore
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Notification Center banners for bots' replies, sign-ins, pauses and calls, in every app. The app sets how its
/// bots look, the sound a reply makes and where pictures are kept, and routes clicks with `click(in:)`.
@MainActor enum AgentNotifications {
    static let conversationIDKey = "conversationID"
    static let messageIDKey = "messageID"
    static let signInKey = "signIn"
    static let callKey = "call"
    static let alertKey = "alert"
    /// One at a time: a call rings again by replacing it.
    private static let ringingIdentifier = "ringing"

    /// The bot's picture beside a banner, drawn at 128 points.
    static var picture: (AgentRecord) -> AnyView = { _ in AnyView(EmptyView()) }
    /// The sound of a reply's banner.
    static var replySound: () -> UNNotificationSound? = { .default }
    /// Called once the person answered the authorization request, as when a badge may now show.
    static var onAuthorized: () -> Void = {}
    /// Where the pictures are written for Notification Center, under the app's Caches.
    static var picturesFolder = ["NotificationPictures"]

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pdparchitect.noodle", category: "Notifications")

    /// While the app is in front with a window open, its sidebar and conversations show what arrived.
    static var shouldPresentActivity: Bool {
        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
        return !NSApp.isActive || !hasVisibleWindow
    }

    static func configure(delegate: any UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            // The saved unread count may have been applied before badges were authorized.
            Task { @MainActor in onAuthorized() }
        }
    }

    static func content(message: ChatMessage, from agent: AgentRecord, in conversation: BotConversation) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        if conversation.kind == .group {
            content.subtitle = conversation.displayName
        }
        content.body = MessageSegment.notificationText(message.body)
        content.userInfo = [conversationIDKey: conversation.id.uuidString, messageIDKey: message.id.uuidString]
        return content
    }

    /// Posts the bots' replies among `messages`, those that notify, once the reply sound has had its say: the person's
    /// own messages and the app's notices never post.
    static func post(replies messages: [ChatMessage], agent: (UUID) -> AgentRecord?, conversation: (UUID) -> BotConversation?) {
        guard !messages.isEmpty, MessageReceivedSound.announce(newMessages: messages.count) else { return }
        for message in messages {
            guard case .agent(let id) = message.author, let agent = agent(id),
                  let conversation = conversation(message.conversationID) else { continue }
            post(message: message, from: agent, in: conversation)
        }
    }

    static func post(message: ChatMessage, from agent: AgentRecord, in conversation: BotConversation) {
        guard shouldPresentActivity else { return }
        let content = content(message: message, from: agent, in: conversation)
        content.sound = replySound()
        add(content, identifier: message.id.uuidString, agent: agent, pictureName: message.id.uuidString)
    }

    /// Rings for a call a bot placed. It is time-sensitive, so it rings through a Focus that lets the app's
    /// time-sensitive notifications through, and Focus and Do Not Disturb silence it otherwise. The panel shows who calls.
    static func ring(_ call: AgentCallRequest, from agent: AgentRecord) {
        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        content.body = MessageSegment.notificationText(call.reason)
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = [conversationIDKey: call.conversationID.uuidString, callKey: call.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ringingIdentifier, content: content, trigger: nil))
    }

    static func stopRinging() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [ringingIdentifier])
    }

    /// Takes back the replies shown from a conversation, as when its group is muted.
    static func withdraw(conversation id: UUID) {
        Task {
            let center = UNUserNotificationCenter.current()
            let shown = await center.deliveredNotifications().filter {
                $0.request.content.userInfo[conversationIDKey] as? String == id.uuidString
                    && $0.request.content.userInfo[messageIDKey] != nil
            }
            center.removeDeliveredNotifications(withIdentifiers: shown.map(\.request.identifier))
        }
    }

    /// Shown even while the app is in front: the bot waits until the person signs in.
    static func postSignInRequired(for agent: AgentRecord) {
        let harness = HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.displayName ?? "The harness"
        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        content.body = "\(harness) needs you to sign in again."
        content.sound = .default
        content.userInfo = [signInKey: true]
        // One per bot: a later expiry replaces the earlier banner.
        add(content, identifier: "sign-in-\(agent.id.uuidString)", agent: agent, pictureName: UUID().uuidString)
    }

    /// Only while the app is in the background: in front, the sidebar and the conversation show it.
    static func postPaused(_ agent: AgentRecord, summary: String, detail: String, conversationID: UUID?) {
        guard shouldPresentActivity else { return }
        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        content.subtitle = summary
        content.body = detail
        content.sound = .default
        if let conversationID { content.userInfo = [conversationIDKey: conversationID.uuidString] }
        // One per bot: a later pause replaces the earlier banner.
        add(content, identifier: "paused-\(agent.id.uuidString)", agent: agent, pictureName: UUID().uuidString)
    }

    /// Something a bot did that the person must hear of even with the app in front, such as a conversation it started;
    /// a click opens that conversation.
    static func postAlert(from agent: AgentRecord, subtitle: String, body: String, conversationID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        content.subtitle = subtitle
        content.body = MessageSegment.notificationText(body)
        content.sound = .default
        content.userInfo = [conversationIDKey: conversationID.uuidString, alertKey: true]
        add(content, identifier: "alert-\(conversationID.uuidString)", agent: agent, pictureName: UUID().uuidString)
    }

    /// How a banner shows while the app is in front: a ringing call only rings, since its panel shows who calls; a
    /// sign-in or an alert always shows; anything else only while the app is away.
    static func presentation(of notification: UNNotification) -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        if info[callKey] != nil { return [.sound] }
        return info[signInKey] != nil || info[alertKey] != nil || shouldPresentActivity ? [.banner, .sound] : []
    }

    /// What a clicked banner is about.
    struct Click {
        let conversationID: UUID?
        let messageID: UUID?
        let isSignIn: Bool
    }

    nonisolated static func click(in response: UNNotificationResponse) -> Click {
        let info = response.notification.request.content.userInfo
        return Click(conversationID: (info[conversationIDKey] as? String).flatMap(UUID.init),
                     messageID: (info[messageIDKey] as? String).flatMap(UUID.init), isSignIn: info[signInKey] != nil)
    }

    private static func add(_ content: UNMutableNotificationContent, identifier: String, agent: AgentRecord, pictureName: String) {
        if let attachment = pictureAttachment(for: agent, name: pictureName) { content.attachments = [attachment] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { logger.error("Unable to deliver notification: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private static func pictureAttachment(for agent: AgentRecord, name: String) -> UNNotificationAttachment? {
        let renderer = ImageRenderer(content: picture(agent).padding(8).environment(\.displayScale, 2))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            logger.error("Unable to render the notification picture for \(agent.displayName, privacy: .public)")
            return nil
        }
        do {
            var directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            for component in picturesFolder { directory.appendPathComponent(component, isDirectory: true) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(name.lowercased()).png")
            try png.write(to: file, options: .atomic)
            return try UNNotificationAttachment(identifier: "bot-avatar", url: file,
                                                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
        } catch {
            logger.error("Unable to attach the bot's picture: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
