import CloudKit
import HubLink
import Observation
import os
import UIKit
import UserNotifications

/// What notifications need from CloudKit: to hear of the records a Hub leaves under a topic.
protocol PushSubscriptions: Sendable {
    func subscribe(topic: String) async throws
    func unsubscribe(topic: String) async throws
}

/// Listens in CloudKit's public database for the record a Hub leaves while replies wait unread, and
/// has Apple show it as a notification, one per conversation, which the app may change before it shows.
struct CloudKitSubscriptions: PushSubscriptions {
    func subscribe(topic: String) async throws {
        let results = try await database.modifySubscriptions(saving: [Self.subscription(topic: topic), Self.withdrawals(topic: topic)],
                                                             deleting: [])
        for result in results.saveResults.values { _ = try result.get() }
    }

    func unsubscribe(topic: String) async throws {
        let results = try await database.modifySubscriptions(saving: [], deleting: [Self.subscriptionID(topic), Self.withdrawalsID(topic)])
        for result in results.deleteResults.values {
            do { try result.get() } catch let error as CKError where error.code == .unknownItem {}
        }
    }

    private var database: CKDatabase { CKContainer(identifier: LinkPush.container).publicCloudDatabase }

    static func subscriptionID(_ topic: String) -> CKSubscription.ID { "unread-\(topic)" }

    static func subscription(topic: String) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(recordType: LinkPush.recordType,
                                               predicate: NSPredicate(format: "%K == %@", LinkPush.topicField, topic),
                                               subscriptionID: subscriptionID(topic),
                                               options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "New reply"
        info.soundName = "default"
        info.desiredKeys = [LinkPush.topicField, LinkPush.conversationField, LinkPush.unreadField]
        // A newer count replaces the conversation's notification rather than adding another.
        info.collapseIDKey = LinkPush.conversationField
        info.shouldSendMutableContent = true
        subscription.notificationInfo = info
        return subscription
    }

    static func withdrawalsID(_ topic: String) -> CKSubscription.ID { "\(PushTopic.withdrawalPrefix)\(topic)" }

    /// Hears in silence when the Hub takes its word back, once the replies were read on any device,
    /// so the app can take the conversation off its icon's number and its notification away. iOS
    /// passes it on only while the app was not closed from the app switcher.
    static func withdrawals(topic: String) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(recordType: LinkPush.recordType,
                                               predicate: NSPredicate(format: "%K == %@", LinkPush.topicField, topic),
                                               subscriptionID: withdrawalsID(topic),
                                               options: [.firesOnRecordDeletion])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }
}

/// Tells each Hub the phone joined where to leave word of unread replies while the phone is away,
/// and listens there.
@MainActor final class HubNotifications {
    private let subscriptions: any PushSubscriptions
    private let defaults: UserDefaults
    /// Topics listened on, so those of Hubs the phone has since left can be dropped.
    private static let listeningKey = "pushTopics"

    init(subscriptions: any PushSubscriptions = CloudKitSubscriptions(), defaults: UserDefaults = .standard) {
        self.subscriptions = subscriptions
        self.defaults = defaults
    }

    /// Listens for each Hub's word, or stops when notifications are not allowed. A Hub is given its
    /// topic only once the phone listens on it; one out of reach hears the next time.
    func register(_ pairings: [HubPairing], allowed: Bool) async {
        var listening: Set<String> = []
        for pairing in pairings {
            let topic = PushTopic.topic(for: pairing)
            if allowed {
                do {
                    try await subscriptions.subscribe(topic: topic)
                    listening.insert(topic)
                    Self.log.notice("Listening in CloudKit for a Hub's unread replies")
                } catch {
                    Self.log.error("CloudKit refused to listen for a Hub's unread replies: \(Self.describe(error), privacy: .public)")
                }
            }
            if !listening.contains(topic) { try? await subscriptions.unsubscribe(topic: topic) }
            do {
                _ = try await pairing.request(.pushTopic(LinkPushTopic(topic: listening.contains(topic) ? topic : nil)))
                Self.log.notice("A Hub was told \(listening.contains(topic) ? "where to notify this phone" : "not to notify this phone", privacy: .public)")
            } catch {
                Self.log.error("A Hub could not be told where to notify this phone: \(error.localizedDescription, privacy: .public)")
            }
        }
        for topic in Set(defaults.stringArray(forKey: Self.listeningKey) ?? []).subtracting(listening) {
            try? await subscriptions.unsubscribe(topic: topic)
        }
        defaults.set(listening.sorted(), forKey: Self.listeningKey)
    }

    /// Asks the first time; after that the person's answer stands until they change it in Settings.
    /// CloudKit takes a subscription only once the phone is registered for push, so this waits for that too.
    static func allowed(registering delegate: AppDelegate) async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        log.notice("Notifications \(granted ? "allowed" : "not allowed", privacy: .public)")
        return granted ? await delegate.registerForPush() : false
    }

    /// What happens to notifications, without topics, keys or messages. Read in the Mac's Console
    /// with the phone connected.
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NoodleMobile", category: "Notifications")

    /// CloudKit's code and reason, which name what it refused. Its description is left out: it names
    /// the subscription, and with it the topic.
    static func describe(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        let reason = (error.userInfo["ServerErrorDescription"] as? String) ?? "no reason given"
        return "CloudKit error \(error.code.rawValue): \(reason)"
    }

    /// A conversation read here needs no notification any more.
    static func clearDelivered(conversation: UUID) async {
        await clearDelivered { $0.conversation == conversation }
    }

    static func clearDelivered(where read: (NotificationRoute) -> Bool) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let cleared = delivered.filter { PushTopic.route(userInfo: $0.request.content.userInfo).map(read) ?? false }
        center.removeDeliveredNotifications(withIdentifiers: cleared.map(\.request.identifier))
    }
}

extension AppBadge {
    /// What the app knows of each Hub it is connected to, then the icon's number. A Hub not
    /// connected keeps what was last known, with what the notification extension added since.
    @MainActor static func publish(_ hubs: [HubChats]) {
        guard let folder = hubs.first?.pairing.directory.deletingLastPathComponent() else { return }
        for hub in hubs {
            if let unread = hub.badgedConversations { setUnread(unread, in: hub.pairing.directory) }
        }
        let total = count(hubs: folder)
        Task { await show(total) }
    }
}

/// Where tapped notifications arrive, and the conversation the app should open.
@MainActor @Observable final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    var opening: NotificationRoute?
    /// Whether this launch registered for push, once known, and who waits to hear.
    @ObservationIgnored private var registered: Bool?
    @ObservationIgnored private var waiting: [CheckedContinuation<Bool, Never>] = []

    func registerForPush() async -> Bool {
        if let registered { return registered }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 1 { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        HubNotifications.log.notice("Registered for push")
        finishRegistering(true)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        HubNotifications.log.error("Could not register for push: \(error.localizedDescription, privacy: .public)")
        finishRegistering(false)
    }

    private func finishRegistering(_ success: Bool) {
        registered = success
        waiting.forEach { $0.resume(returning: success) }
        waiting = []
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ApprovalNotifications.register()
        // Before anything else: a VoIP push that launched the app must reach the call screen at once.
        CallPushes.shared.start()
        return true
    }

    /// The app on screen shows replies as they come; a call held for the person shows anyway, as it waits on them.
    // Both on the main actor: iOS requires their answers there, and aborts the app otherwise.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == ApprovalNotifications.category ? [.banner, .list, .sound] : []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // Approve or Decline decides without opening anything; the notification itself opens the call in full.
        if let held = ApprovalNotifications.decision(in: response) {
            if let decision = held.decision { return await ApprovalNotifications.decide(decision, topic: held.topic) }
            opening = held.route
            return
        }
        opening = PushTopic.route(userInfo: response.notification.request.content.userInfo)
    }

    /// Replies read on another device, as the Hub takes its word back: off the icon's number and
    /// out of Notification Center.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let withdrawal = PushTopic.withdrawal(userInfo: userInfo), let hubs = AppGroup.hubs else { return .noData }
        let changed = AppBadge.withdrawn(withdrawal, hubs: hubs)
        if changed { await AppBadge.show(AppBadge.count(hubs: hubs)) }
        await HubNotifications.clearDelivered(where: withdrawal.matches)
        return changed ? .newData : .noData
    }
}
