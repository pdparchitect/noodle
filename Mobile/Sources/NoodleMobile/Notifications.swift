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
        let results = try await database.modifySubscriptions(saving: [Self.subscription(topic: topic)], deleting: [])
        for result in results.saveResults.values { _ = try result.get() }
    }

    func unsubscribe(topic: String) async throws {
        let results = try await database.modifySubscriptions(saving: [], deleting: [Self.subscriptionID(topic)])
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
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let read = delivered.filter { PushTopic.route(userInfo: $0.request.content.userInfo)?.conversation == conversation }
        center.removeDeliveredNotifications(withIdentifiers: read.map(\.request.identifier))
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
        return true
    }

    /// The app on screen shows replies as they come.
    // Both on the main actor: iOS requires their answers there, and aborts the app otherwise.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        opening = PushTopic.route(userInfo: response.notification.request.content.userInfo)
    }
}
