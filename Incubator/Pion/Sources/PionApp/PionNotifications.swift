import AppKit
import HubLink
import NoodleCore
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Notification Center banners for agent replies, sign-ins and pauses, as Noodle shows them.
@MainActor enum PionNotifications {
    static let conversationIDKey = "conversationID"
    static let messageIDKey = "messageID"
    static let signInKey = "signIn"
    static let callKey = "call"
    /// One at a time: a call rings again by replacing it.
    private static let ringingIdentifier = "Pion.ringing"

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pdparchitect.pion", category: "Notifications")

    /// While Pion is in front with a window open, its sidebar and conversations show what arrived.
    static var shouldPresentActivity: Bool {
        !NSApp.isActive || !NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
    }

    static func configure(delegate: any UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error { logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    static func post(_ message: ChatMessage, from agent: AgentRecord, in conversation: BotConversation) {
        guard shouldPresentActivity else { return }
        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        if conversation.kind == .group { content.subtitle = conversation.displayName }
        content.body = MessageSegment.notificationText(message.body)
        content.sound = .default
        content.userInfo = [conversationIDKey: conversation.id.uuidString, messageIDKey: message.id.uuidString]
        add(content, identifier: message.id.uuidString, agent: agent)
    }

    /// Shown even while Pion is in front: the agent waits until the champion signs in.
    static func postSignInRequired(for agent: AgentRecord) {
        let harness = HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.displayName ?? "The harness"
        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        content.body = "\(harness) needs you to sign in again."
        content.sound = .default
        content.userInfo = [signInKey: true]
        // One per agent: a later expiry replaces the earlier banner.
        add(content, identifier: "sign-in-\(agent.id.uuidString)", agent: agent)
    }

    static func postPaused(_ agent: AgentRecord, summary: String, detail: String, conversationID: UUID?) {
        guard shouldPresentActivity else { return }
        let content = UNMutableNotificationContent()
        content.title = agent.displayName
        content.subtitle = summary
        content.body = detail
        content.sound = .default
        if let conversationID { content.userInfo = [conversationIDKey: conversationID.uuidString] }
        // One per agent: a later pause replaces the earlier banner.
        add(content, identifier: "paused-\(agent.id.uuidString)", agent: agent)
    }

    /// Rings for a call an agent placed. It is time-sensitive, so it rings through a Focus that lets Pion's
    /// time-sensitive notifications through; the ringing panel shows who calls.
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

    private static func add(_ content: UNMutableNotificationContent, identifier: String, agent: AgentRecord) {
        if let mark = markAttachment(for: agent) { content.attachments = [mark] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { logger.error("Unable to deliver notification: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// The agent's mark beside the banner.
    private static func markAttachment(for agent: AgentRecord) -> UNNotificationAttachment? {
        let renderer = ImageRenderer(content: AgentMark(agent: agent, size: 128).padding(8))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NotificationMarks", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The system moves the file into its own store, so each banner needs one of its own.
            let file = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
            try png.write(to: file, options: .atomic)
            return try UNNotificationAttachment(identifier: "agent-mark", url: file,
                                                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
        } catch {
            logger.error("Unable to attach the agent's mark: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension PionDelegate: UNUserNotificationCenterDelegate {
    /// Agent replies and pauses on what arrived while Pion was away; sign-ins whenever they are needed.
    func connectNotifications() {
        PionNotifications.configure(delegate: self)
        model.onMessagesArrived = { [weak self] messages in
            guard let model = self?.model else { return }
            for message in messages {
                guard case .agent(let id) = message.author, let agent = model.agent(id),
                      let conversation = model.conversation(message.conversationID) else { continue }
                PionNotifications.post(message, from: agent, in: conversation)
            }
        }
        model.onNotificationsNarrowed = { PionNotifications.withdraw(conversation: $0) }
        model.runtime.onSignInRequired = { [weak self] id in
            guard let agent = self?.model.agent(id) else { return }
            PionNotifications.postSignInRequired(for: agent)
        }
        model.runtime.onPaused = { [weak self] id in
            guard let model = self?.model, let agent = model.agent(id),
                  let summary = model.runtime.snapshot(for: id).pauseSummary else { return }
            PionNotifications.postPaused(agent, summary: summary, detail: model.runtime.snapshot(for: id).detail,
                                         conversationID: model.directConversation(of: agent)?.id)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let signIn = notification.request.content.userInfo[PionNotifications.signInKey] != nil
        // A ringing call only rings, in front or not: its panel shows who calls.
        let call = notification.request.content.userInfo[PionNotifications.callKey] != nil
        Task { @MainActor in
            completionHandler(call ? [.sound] : signIn || PionNotifications.shouldPresentActivity ? [.banner, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let conversationID = (userInfo[PionNotifications.conversationIDKey] as? String).flatMap(UUID.init)
        let messageID = (userInfo[PionNotifications.messageIDKey] as? String).flatMap(UUID.init)
        let signIn = userInfo[PionNotifications.signInKey] != nil
        Task { @MainActor in
            if signIn {
                settings.selectedTab = .harnesses
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            if let conversationID, model.conversation(conversationID) != nil {
                model.selection = conversationID
                window.openMain?()
                if let messageID { NotificationCenter.default.post(name: .revealTranscriptMessage, object: messageID) }
            }
            NSApp.activate(ignoringOtherApps: true)
            completionHandler()
        }
    }
}
