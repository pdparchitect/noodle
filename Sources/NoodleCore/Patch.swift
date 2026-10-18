// Patches are read by a package Noodle Mobile shares; whatever imports NoodleCore reads them with it.
@_exported import NoodlePatch

extension PatchReviewStore {
    public func viewed(_ attachment: ConversationAttachment) -> Set<String> {
        viewed(attachment: attachment.id, in: attachment.conversationID)
    }

    public func save(_ paths: Set<String>, for attachment: ConversationAttachment) throws {
        try save(paths, attachment: attachment.id, in: attachment.conversationID)
    }
}
