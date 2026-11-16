import AppKit
import NoodleCore
import SwiftUI
import UserNotifications

/// Pion's side of Noodle's notifications: what posts them, and where a click on one goes.
extension PionDelegate: UNUserNotificationCenterDelegate {
    /// Agent replies and pauses on what arrived while Pion was away; sign-ins whenever they are needed.
    func connectNotifications() {
        // Noodle's notifications, with Pion's agent marks.
        AgentNotifications.picture = { AnyView(AgentMark(agent: $0, size: 128)) }
        AgentNotifications.onAuthorized = { [weak self] in self?.model.refreshBadge() }
        AgentNotifications.picturesFolder = ["NotificationMarks"]
        // Noodle's reply sound, as chosen in Settings › Conversation.
        AgentNotifications.replySound = { MessageReceivedSound.notificationSound() }
        AgentNotifications.configure(delegate: self)
        model.onMessagesArrived = { [weak self] messages in
            guard let model = self?.model, MessageReceivedSound.announce(newMessages: messages.count) else { return }
            for message in messages {
                guard case .agent(let id) = message.author, let agent = model.agent(id),
                      let conversation = model.conversation(message.conversationID) else { continue }
                AgentNotifications.post(message: message, from: agent, in: conversation)
            }
        }
        model.onNotificationsNarrowed = { AgentNotifications.withdraw(conversation: $0) }
        // As Noodle's: the Dock shows how many conversations wait for the champion.
        model.onBadge = { NSApp.dockTile.badgeLabel = $0 == 0 ? nil : String($0) }
        model.runtime.onSignInRequired = { [weak self] id in
            guard let agent = self?.model.agent(id) else { return }
            AgentNotifications.postSignInRequired(for: agent)
        }
        model.runtime.onPaused = { [weak self] id in
            guard let model = self?.model, let agent = model.agent(id),
                  let summary = model.runtime.snapshot(for: id).pauseSummary else { return }
            AgentNotifications.postPaused(agent, summary: summary, detail: model.runtime.snapshot(for: id).detail,
                                         conversationID: model.directConversation(of: agent)?.id)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in completionHandler(AgentNotifications.presentation(of: notification)) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let click = AgentNotifications.click(in: response)
        let conversationID = click.conversationID, messageID = click.messageID, signIn = click.isSignIn
        Task { @MainActor in
            if signIn {
                settings.selectedTab = .harnesses
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            if let conversationID, model.conversation(conversationID) != nil {
                showConversation(conversationID)
                if let messageID { NotificationCenter.default.post(name: .revealTranscriptMessage, object: messageID) }
            }
            NSApp.activate(ignoringOtherApps: true)
            completionHandler()
        }
    }
}
