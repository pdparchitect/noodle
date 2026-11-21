import HubLink
import OSLog
import SwiftUI
import UIKit
import UserNotifications

/// A call one of the person's bots holds for their approval, from whichever Hub runs it.
struct ApprovalEntry: Identifiable {
    let chats: HubChats
    let bot: LinkBot
    let approval: LinkApproval
    var id: UUID { approval.id }

    /// Every held call of the person's own bots, on every Hub, oldest first. Unlike tasks they are never filtered or
    /// left to one space: a held call waits until the person decides it.
    @MainActor static func listed(in hubs: [HubChats]) -> [ApprovalEntry] {
        hubs.flatMap { chats in
            chats.agents.filter { $0.owner == nil && $0.archivedAt == nil }.flatMap { bot in
                bot.approvals.map { ApprovalEntry(chats: chats, bot: bot, approval: $0) }
            }
        }.sorted { $0.approval.createdAt < $1.approval.createdAt }
    }

    /// The call in a few words, from the call itself: the tool and the first value it is given, such as who.
    var action: String {
        guard let first = approval.inputLines.first?.value, !first.isEmpty else { return approval.tool }
        return "\(approval.tool) \(first)"
    }

    @MainActor var thread: HubThread? { chats.threads.first { $0.conversationID == approval.conversationID } }
}

extension HubChats {
    /// The person's decision on a call one of their bots holds; the Hub runs an approved one, then the list follows.
    func decide(_ approval: LinkApproval, of bot: LinkBot, approve: Bool) async throws {
        _ = try await pairing.request(.decideApproval(LinkApprovalDecision(botID: bot.id, approvalID: approval.id, approve: approve)))
        try await reload()
    }
}

/// A notification for each call a bot holds for the person, with Approve and Decline, which decide it without opening
/// the app. Posted as the app hears of the call from the Hub, and taken back once it is decided on any device.
enum ApprovalNotifications {
    static let category = "approval"
    static let approveAction = "approve", declineAction = "decline"
    static let approvalKey = "approval", botKey = "bot"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NoodleMobile", category: "Approvals")

    /// Either button needs the phone unlocked.
    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: category, actions: [
            UNNotificationAction(identifier: approveAction, title: "Approve", options: [.authenticationRequired]),
            UNNotificationAction(identifier: declineAction, title: "Decline", options: [.authenticationRequired, .destructive]),
        ], intentIdentifiers: [])])
    }

    /// Announces the Hub's new held calls, takes back those decided, and keeps the icon's number, from the list just
    /// heard. Only the person's own bots hold calls for them.
    @MainActor static func sync(_ chats: HubChats) {
        let directory = chats.pairing.directory
        let entries = ApprovalEntry.listed(in: [chats])
        let changes = LinkApproval.changes(listed: entries.map(\.approval), known: AppBadge.pendingApprovals(in: directory))
        let topic = PushTopic.topic(for: chats.pairing)
        let center = UNUserNotificationCenter.current()
        for approval in changes.new {
            guard let entry = entries.first(where: { $0.id == approval.id }) else { continue }
            center.add(UNNotificationRequest(identifier: approval.notificationIdentifier, content: content(for: entry, topic: topic), trigger: nil))
        }
        if !changes.gone.isEmpty { center.removeDeliveredNotifications(withIdentifiers: changes.gone.map(LinkApproval.notificationIdentifier)) }
        guard changes.pending != AppBadge.pendingApprovals(in: directory) else { return }
        AppBadge.setPendingApprovals(changes.pending, in: directory)
        let hubs = directory.deletingLastPathComponent()
        Task { await AppBadge.show(AppBadge.count(hubs: hubs)) }
    }

    /// Exactly what will run, from the call itself, and the bot's reason. Tapping it opens the call in full.
    private static func content(for entry: ApprovalEntry, topic: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = entry.bot.draft.name
        content.subtitle = "Asks to run \(entry.approval.tool) on \(entry.approval.providerTitle)"
        let input = entry.approval.inputLines.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        content.body = MessageSegment.notificationText([input, entry.approval.reason].filter { !$0.isEmpty }.joined(separator: "\n"))
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = entry.approval.conversationID.uuidString
        content.userInfo = [LinkPush.topicField: topic, LinkPush.conversationField: entry.approval.conversationID.uuidString,
                            approvalKey: entry.approval.id.uuidString, botKey: entry.bot.id.uuidString]
        return content
    }

    /// The call a notification is about, with the decision when one of its buttons was chosen.
    static func decision(in response: UNNotificationResponse) -> (topic: String, decision: LinkApprovalDecision?, route: NotificationRoute)? {
        let info = response.notification.request.content.userInfo
        guard response.notification.request.content.categoryIdentifier == category,
              let topic = info[LinkPush.topicField] as? String,
              let conversation = (info[LinkPush.conversationField] as? String).flatMap(UUID.init(uuidString:)),
              let approval = (info[approvalKey] as? String).flatMap(UUID.init(uuidString:)),
              let bot = (info[botKey] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        let approve: Bool? = switch response.actionIdentifier {
        case approveAction: true
        case declineAction: false
        default: nil
        }
        return (topic, approve.map { LinkApprovalDecision(botID: bot, approvalID: approval, approve: $0) },
                NotificationRoute(topic: topic, conversation: conversation, approval: approval))
    }

    /// Sends a button's decision to the Hub the call is on, with the app in the background. If the Hub cannot be
    /// reached, a notification says so, as the call still waits.
    @MainActor static func decide(_ decision: LinkApprovalDecision, topic: String) async {
        guard let hubs = AppGroup.hubs, let directory = PushTopic.directory(of: topic, in: hubs) else { return }
        do {
            _ = try await HubPairing(directory: directory, deviceName: UIDevice.current.name).request(.decideApproval(decision))
            AppBadge.setPendingApprovals(AppBadge.pendingApprovals(in: directory).subtracting([decision.approvalID]), in: directory)
            await AppBadge.show(AppBadge.count(hubs: hubs))
        } catch {
            log.error("A decision could not reach the Hub: \(error.localizedDescription, privacy: .public)")
            let content = UNMutableNotificationContent()
            content.title = "Not decided"
            content.body = "\(error.localizedDescription) The call still waits for you in Noodle."
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

struct ApprovalListRow: View {
    let entry: ApprovalEntry

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(face: BotFace(entry.bot), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.action)
                    .lineLimit(1)
                Text("\(entry.bot.draft.name) · \(entry.approval.providerTitle)")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(entry.approval.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
    }
}

/// One held call in full: exactly what will run, from the call itself, and the bot's reason, marked as its own words.
struct ApprovalSheet: View {
    let entry: ApprovalEntry
    let openConversation: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var deciding = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !entry.approval.toolDescription.isEmpty {
                        Text(entry.approval.toolDescription).foregroundStyle(.secondary)
                    }
                    ForEach(entry.approval.inputLines, id: \.name) { line in
                        LabeledContent(line.name) {
                            Text(line.value)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text(entry.approval.providerTitle)
                }
                Section {
                    Text(entry.approval.reason)
                } header: {
                    Text("\(entry.bot.draft.name) says")
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button("Approve") { decide(true) }
                    Button("Decline", role: .destructive) { decide(false) }
                }
                .disabled(deciding)
                if entry.thread != nil {
                    Section {
                        Button("Open Conversation") {
                            dismiss()
                            openConversation()
                        }
                    }
                }
            }
            .navigationTitle(entry.approval.tool)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func decide(_ approve: Bool) {
        deciding = true
        Task {
            do {
                try await entry.chats.decide(entry.approval, of: entry.bot, approve: approve)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                deciding = false
            }
        }
    }
}
