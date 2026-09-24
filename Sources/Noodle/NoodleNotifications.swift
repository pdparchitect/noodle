import AppKit
import Foundation
import OSLog
import NoodleCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import NoodleRuntimeSettings

enum NoodleNotifications {
    static let conversationIDKey = "conversationID"
    static let messageIDKey = "messageID"

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

    @MainActor
    static func post(
        message: ChatMessage,
        from agent: AgentRecord,
        in conversation: BotConversation
    ) {
        guard shouldPresentActivity else { return }

        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        if conversation.kind == .group {
            content.subtitle = conversation.displayName
        }
        content.body = message.body
        content.sound = .default
        content.userInfo = [conversationIDKey: conversation.id.uuidString, messageIDKey: message.id.uuidString]
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

    @MainActor
    private static func avatarAttachment(
        for agent: AgentRecord,
        messageID: UUID
    ) -> UNNotificationAttachment? {
        let renderer = ImageRenderer(
            content: BotAvatar(agent: agent, size: 128)
                .padding(8)
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
