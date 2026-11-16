import AppKit
import Foundation
import OSLog
import NoodleCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import NoodleRuntimeSettings
import HubLink

extension AgentNotifications {
    /// Noodle's look and sound: the bot's picture, the reply sound chosen in Settings, and its own pictures folder.
    @MainActor static func configureForNoodle(delegate: any UNUserNotificationCenterDelegate) {
        picture = { AnyView(BotAvatar(agent: $0, size: 128)) }
        replySound = { MessageReceivedSound.notificationSound() }
        onAuthorized = { NoodleStore.active?.updateDockBadge() }
        picturesFolder = ["Noodle", "NotificationAvatars"]
        configure(delegate: delegate)
    }
}

extension NoodleStore {
    /// Shows a message in its conversation: a transcript mounted later restores the place, and one already on
    /// screen scrolls to it. The latest message is the bottom, which keeps following new replies.
    func revealMessage(_ messageID: UUID, in conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              messages(for: conversation).contains(where: { $0.id == messageID }) else { return }
        let isLatest = messages(for: conversation).last?.id == messageID
        saveTranscriptViewport(isLatest ? TranscriptViewport()
            : TranscriptViewport(isAtBottom: false, messageID: messageID), for: conversationID)
        NotificationCenter.default.post(name: .revealTranscriptMessage, object: messageID)
    }

    /// Lands on the notified message, in whichever window shows its conversation.
    func openNotification(conversationID: UUID, messageID: UUID?) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        if let messageID { revealMessage(messageID, in: conversationID) }
        guard !conversationWindows.focus(conversationID) else { return }
        // Also covers a closed main window and a launch from the notification, before any window exists.
        selectedConversationID = conversationID
        conversationWindows.showMainWindow()
    }
}

