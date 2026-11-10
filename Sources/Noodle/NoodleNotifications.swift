import AppKit
import Foundation
import OSLog
import NoodleCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import NoodleRuntimeSettings
import HubLink

enum NoodleNotifications {
    static let conversationIDKey = "conversationID"
    static let messageIDKey = "messageID"
    static let signInKey = "signIn"
    static let callKey = "call"
    /// One at a time: a call rings again by replacing it.
    private static let ringingIdentifier = "Noodle.ringing"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pdparchitect.noodle",
        category: "Notifications"
    )

    @MainActor
    static var shouldPresentActivity: Bool {
        let hasVisibleWindow = NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized
        }
        return !NSApp.isActive || !hasVisibleWindow
    }

    static func configure(delegate: any UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                // The saved unread count may have been applied before badges were authorized.
                NoodleStore.active?.updateDockBadge()
            }
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

    @MainActor
    static func post(
        message: ChatMessage,
        from agent: AgentRecord,
        in conversation: BotConversation
    ) {
        guard shouldPresentActivity else { return }

        let content = content(message: message, from: agent, in: conversation)
        content.sound = MessageReceivedSound.notificationSound()
        if let avatar = avatarAttachment(for: agent, messageID: message.id) {
            content.attachments = [avatar]
        }

        let request = UNNotificationRequest(
            identifier: message.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Unable to deliver notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Rings for a call a bot placed. It is time-sensitive, so it rings through a Focus that lets Noodle's
    /// time-sensitive notifications through, and Focus and Do Not Disturb silence it otherwise. The panel shows who calls.
    @MainActor
    static func ring(_ call: AgentCallRequest, from agent: AgentRecord) {
        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        content.body = MessageSegment.notificationText(call.reason)
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = [conversationIDKey: call.conversationID.uuidString, callKey: call.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ringingIdentifier, content: content, trigger: nil))
    }

    /// Takes back the replies shown from a conversation, as when its group is muted.
    @MainActor
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

    @MainActor
    static func stopRinging() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [ringingIdentifier])
    }

    /// Shown even while Noodle is in front: the bot waits until the person signs in.
    @MainActor
    static func postSignInRequired(for agent: AgentRecord) {
        let harness = HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.displayName ?? "The harness"
        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        content.body = "\(harness) needs you to sign in again."
        content.sound = .default
        content.userInfo = [signInKey: true]
        if let avatar = avatarAttachment(for: agent, messageID: UUID()) {
            content.attachments = [avatar]
        }
        // One per bot: a later expiry replaces the earlier banner.
        let request = UNNotificationRequest(identifier: "sign-in-\(agent.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Unable to deliver notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Only while Noodle is in the background: in front, the sidebar and the conversation show it.
    @MainActor
    static func postPaused(_ agent: AgentRecord, summary: String, detail: String, conversationID: UUID?) {
        guard shouldPresentActivity else { return }
        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        content.subtitle = summary
        content.body = detail
        content.sound = .default
        if let conversationID { content.userInfo = [conversationIDKey: conversationID.uuidString] }
        if let avatar = avatarAttachment(for: agent, messageID: UUID()) {
            content.attachments = [avatar]
        }
        // One per bot: a later pause replaces the earlier banner.
        let request = UNNotificationRequest(identifier: "paused-\(agent.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Unable to deliver notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    private static func avatarAttachment(
        for agent: AgentRecord,
        messageID: UUID
    ) -> UNNotificationAttachment? {
        let renderer = ImageRenderer(
            content: BotAvatar(agent: agent, size: 128)
                .padding(8)
                .environment(\.displayScale, 2)
        )
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            logger.error("Unable to render the notification avatar for \(agent.displayName, privacy: .public)")
            return nil
        }

        do {
            let directory = try notificationAttachmentDirectory()
            let file = directory.appendingPathComponent(
                "\(messageID.uuidString.lowercased()).png"
            )
            try png.write(to: file, options: .atomic)
            return try UNNotificationAttachment(
                identifier: "bot-avatar",
                url: file,
                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier]
            )
        } catch {
            logger.error("Unable to attach the bot avatar: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func notificationAttachmentDirectory() throws -> URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        let directory = caches
            .appendingPathComponent("Noodle", isDirectory: true)
            .appendingPathComponent("NotificationAvatars", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

extension NoodleStore {
    /// Lands on the notified message, in whichever window shows its conversation.
    func openNotification(conversationID: UUID, messageID: UUID?) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        if let messageID, messages(for: conversation).contains(where: { $0.id == messageID }) {
            // The latest message is the bottom, which keeps following new replies.
            let isLatest = messages(for: conversation).last?.id == messageID
            // A transcript mounted later restores this; one already on screen scrolls to it.
            saveTranscriptViewport(isLatest ? TranscriptViewport()
                : TranscriptViewport(isAtBottom: false, messageID: messageID), for: conversationID)
            NotificationCenter.default.post(name: .revealTranscriptMessage, object: messageID)
        }
        guard !conversationWindows.focus(conversationID) else { return }
        // Also covers a closed main window and a launch from the notification, before any window exists.
        selectedConversationID = conversationID
        conversationWindows.showMainWindow()
    }
}

extension Notification.Name {
    static let revealTranscriptMessage = Notification.Name("Noodle.revealTranscriptMessage")
}
