import AppKit
import NoodleCore
import SwiftUI
import UserNotifications

/// Pion's side of Noodle's notifications: what posts them, and where a click on one goes.
extension PionDelegate: UNUserNotificationCenterDelegate {
    /// Agent replies and pauses on what arrived while Pion was away; sign-ins and Investigations agents open whenever they happen.
    func connectNotifications() {
        // Noodle's notifications, with Pion's agent marks.
        AgentNotifications.picture = { AnyView(AgentMark(agent: $0, size: 128)) }
        AgentNotifications.onAuthorized = { [weak self] in self?.model.refreshBadge() }
        AgentNotifications.picturesFolder = ["NotificationMarks"]
        // Noodle's reply sound, as chosen in Settings › Conversation.
        AgentNotifications.replySound = { MessageReceivedSound.notificationSound() }
        AgentNotifications.configure(delegate: self)
        model.onMessagesArrived = { [weak self] messages in
            guard let model = self?.model else { return }
            AgentNotifications.post(replies: messages, agent: { model.agent($0) }, conversation: { model.conversation($0) })
        }
        model.onNotificationsNarrowed = { AgentNotifications.withdraw(conversation: $0) }
        // An agent opening an Investigation shows even with Pion in front, whether or not the agent posts in it.
        model.onAgentOpenedInvestigation = { investigation, agent in
            AgentNotifications.postAlert(from: agent, subtitle: "Opened \(investigation.reference) \(investigation.title)",
                                         body: investigation.objective.isEmpty ? investigation.title : investigation.objective,
                                         conversationID: investigation.id)
        }
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
                if let messageID { model.revealMessage(messageID, in: conversationID) }
                showConversation(conversationID)
            }
            NSApp.activate(ignoringOtherApps: true)
            completionHandler()
        }
    }
}
