import AppKit
import Foundation
import OSLog
import SuperBotCore
import UserNotifications

enum SuperBotNotifications {
    static let conversationIDKey = "conversationID"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pdparchitect.superbot",
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
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
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
        content.userInfo = [conversationIDKey: conversation.id.uuidString]

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
}
