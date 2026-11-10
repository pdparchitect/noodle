import CloudKit
import Foundation
// Everything that imports HubLink sees the wire types as before.
@_exported import HubWire
import ImageIO
@_exported import Surface

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

extension LinkPixelSize {
    /// Reads only the file's header; nil for anything that is not a picture.
    public init?(pictureAt url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        // Orientations 5 to 8 turn the picture a quarter.
        let turned = (5...8).contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
        self.init(width: turned ? height : width, height: turned ? width : height)
    }
}
