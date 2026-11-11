import CloudKit
import Foundation
import HubCore
import HubLink
import Security

/// Leaves word of unread replies in CloudKit's public database, where each device away from the
/// Hub subscribes to its own topic and Apple delivers the notification. Nothing but the topic, the
/// conversation and the count is kept there.
public final class CloudKitPushes: HubPushPublisher {
    private let database: CKDatabase

    private init() {
        database = CKContainer(identifier: LinkPush.container).publicCloudDatabase
    }

    /// Nil unless this app is signed with the iCloud container: CloudKit stops any app that is not,
    /// so tests and development builds never reach it.
    public static func ifEntitled() -> CloudKitPushes? {
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
                as? [String], containers.contains(LinkPush.container) else { return nil }
        return CloudKitPushes()
    }

    public func publish(topic: String, conversation: UUID, unread: Int) async throws {
        // The Hub alone writes these, so its copy always wins.
        let results = try await database.modifyRecords(saving: [LinkPush.record(topic: topic, conversation: conversation, unread: unread)],
                                                       deleting: [], savePolicy: .allKeys)
        // Each record's failure comes in its result rather than thrown.
        for result in results.saveResults.values { _ = try result.get() }
    }

    public func withdraw(topic: String, conversation: UUID) async throws {
        let results = try await database.modifyRecords(saving: [], deleting: [LinkPush.recordID(topic: topic, conversation: conversation)])
        for result in results.deleteResults.values {
            // Unknown: nothing was shown.
            do { try result.get() } catch let error as CKError where error.code == .unknownItem {}
        }
    }
}
