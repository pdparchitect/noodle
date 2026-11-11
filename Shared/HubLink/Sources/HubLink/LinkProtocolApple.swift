#if canImport(CloudKit)
import CloudKit
import Foundation

extension LinkPush {
    /// The same for every write about one device and conversation, so each replaces the last.
    public static func recordID(topic: String, conversation: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(topic: topic, conversation: conversation))
    }

    /// What the Hub writes about one device and conversation. It lives in this package, with the fields, so that
    /// scripts/verify-push-setup.sh can check it against CloudKit's schema while building only this package.
    public static func record(topic: String, conversation: UUID, unread: Int) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(topic: topic, conversation: conversation))
        record[topicField] = topic
        record[conversationField] = conversation.uuidString
        record[unreadField] = Int64(unread)
        return record
    }
}
#endif
