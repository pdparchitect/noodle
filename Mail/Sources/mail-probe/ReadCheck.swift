import MailEngine

/// Whether reading a message works, told without showing it: the length of its text in characters, whether there is any text,
/// and how many attachments it has. Never its text, subject or file names.
struct ReadCheck: Encodable {
    let textLength: Int?
    let hasText: Bool?
    let attachments: Int?
    let error: String?

    /// Reads the message from INBOX and leaves it unread. A failed read is reported with its error text instead of thrown, so the
    /// rest of the probe's report still prints.
    static func of(uid: Int, in session: MailSession) async -> ReadCheck {
        do {
            let detail = try await session.read(uid: uid, markRead: false)
            return ReadCheck(textLength: detail.text.count, hasText: !detail.text.isEmpty, attachments: detail.attachments.count, error: nil)
        } catch {
            return ReadCheck(textLength: nil, hasText: nil, attachments: nil, error: error.localizedDescription)
        }
    }
}
