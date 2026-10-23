import Foundation
import MailCore
import MailEngine

/// A mailbox session that answers from memory and records what it was asked.
final class FakeSession: MailboxSession, @unchecked Sendable {
    var folderList: [MailFolder] = []
    var rows: [MessageRow] = []
    var detail = MessageDetail(uid: 7, from: "ada@example.com", to: ["borek@mail.example.org"], cc: [], date: Date(timeIntervalSince1970: 1_790_000_000),
                               subject: "Invoice", messageId: "<1@example.com>", text: "Hello", attachments: [])
    var attachmentData = Data("PDF".utf8)
    var failure: Error?
    private(set) var queries: [MessageQuery] = []
    private(set) var reads: [(uid: Int, folder: String, markRead: Bool)] = []
    private(set) var attachments: [(uid: Int, part: String, folder: String)] = []
    private(set) var closed = false
    /// Runs when the session is closed. The runtime closes a failed session in the background, so a test waits on this instead of reading `closed` too early.
    var onClose: (@Sendable () -> Void)?

    private func check() throws { if let failure { throw failure } }
    func folders() async throws -> [MailFolder] { try check(); return folderList }
    func list(_ query: MessageQuery) async throws -> [MessageRow] { try check(); queries.append(query); return rows }
    func read(uid: Int, folder: String, markRead: Bool) async throws -> MessageDetail { try check(); reads.append((uid, folder, markRead)); return detail }
    func attachment(uid: Int, part: String, folder: String) async throws -> Data { try check(); attachments.append((uid, part, folder)); return attachmentData }
    func close() async { closed = true; onClose?() }
}
