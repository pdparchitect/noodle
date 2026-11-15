import Foundation

/// What deleting a bot or a group takes with it, said the same way in every app.
public enum ConversationDeletion {
    public static func message(name: String, isDirect: Bool, bots: String = "bots") -> String {
        if isDirect {
            return "\u{201c}\(name)\u{201d}, its workspace, and its direct conversation will be permanently deleted. It will also be removed from every group. This cannot be undone."
        }
        return "\u{201c}\(name)\u{201d}, its messages, and its attachments will be permanently deleted. The \(bots) in the group will not be deleted. This cannot be undone."
    }
}
