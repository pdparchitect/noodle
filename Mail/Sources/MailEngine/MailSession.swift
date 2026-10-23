import Foundation
import SwiftMail

/// One mailbox, signed in on first use. Calls made at the same time take turns, first come first served, because the IMAP
/// connection has one selected folder and the SMTP connection one mail at a time.
public final class MailSession {
    private let account: MailAccount
    private let password: String
    private let imap: IMAPClient
    private let smtp: SMTPClient
    /// Every public method takes its turn here first, so none may call another public method: it would wait for itself.
    private let calls = CallQueue()
    private var signedIn = false

    public convenience init(account: MailAccount, password: String) throws {
        self.init(account: account, password: password, imap: try SwiftMailIMAPClient(account.imap), smtp: try SwiftMailSMTPClient(account.smtp))
    }

    init(account: MailAccount, password: String, imap: IMAPClient, smtp: SMTPClient) {
        self.account = account
        self.password = password
        self.imap = imap
        self.smtp = smtp
    }

    /// Every folder by the server's raw name, the name every other call takes, with its role when known.
    public func folders() async throws -> [MailFolder] {
        try await calls.enter()
        defer { calls.leave() }
        return try await imapCall { try await self.imap.folders() }
    }

    public func list(_ query: MessageQuery) async throws -> [MessageRow] {
        try await calls.enter()
        defer { calls.leave() }
        return try await imapCall {
            try await self.imap.select(query.folder)
            let uids = MailSearch.page(try await self.imap.search(MailSearch.terms(for: query)), beforeUID: query.beforeUID, limit: query.clampedLimit)
            let byUID = Dictionary(try await self.imap.headers(uids).map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
            return uids.compactMap { byUID[$0] }.map { header in
                MessageRow(uid: header.uid, date: header.date, from: MailText.capped(header.from), subject: MailText.capped(header.subject), seen: header.seen,
                           attachments: MailParts.attachments(in: header.parts, excluding: MailParts.body(in: header.parts)).count)
            }
        }
    }

    /// One message as a bot reads it. `folder` is the server's raw name, as `folders()` returns it. A mail with thousands of
    /// parts would flood a bot, so only the first attachments are listed and the rest are counted.
    public func read(uid: Int, folder: String = "INBOX", markRead: Bool = false) async throws -> MessageDetail {
        try await calls.enter()
        defer { calls.leave() }
        return try await imapCall {
            try await self.imap.select(folder)
            let header = try await self.header(uid: uid)
            let body = MailParts.body(in: header.parts)
            var text = ""
            if let body { text = try await self.text(of: body, uid: uid) }
            // Some mailers send a blank plain-text part beside the HTML that holds the actual message.
            if body?.contentType == "text/plain", text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let html = MailParts.html(in: header.parts) {
                text = try await self.text(of: html, uid: uid)
            }
            if markRead { try await self.imap.markSeen(uid: uid) }
            let attachments = MailParts.attachments(in: header.parts, excluding: body)
            let omitted = attachments.count - MailText.attachmentLimit
            return MessageDetail(uid: uid, from: MailText.capped(header.from), to: MailText.capped(header.to), cc: MailText.capped(header.cc),
                                 date: header.date, subject: MailText.capped(header.subject), messageId: MailText.messageID(header.messageId), text: text,
                                 attachments: Array(attachments.prefix(MailText.attachmentLimit)), attachmentsOmitted: omitted > 0 ? omitted : nil)
        }
    }

    /// An attachment's bytes, by the part number `read` lists. `folder` is the server's raw name, as `folders()` returns it.
    public func attachment(uid: Int, part: String, folder: String = "INBOX") async throws -> Data {
        try await calls.enter()
        defer { calls.leave() }
        return try await imapCall {
            try await self.imap.select(folder)
            let header = try await self.header(uid: uid)
            guard header.parts.contains(where: { $0.section == part }) else { throw MailEngineError.partNotFound(uid: uid, part: part) }
            return try await self.imap.partData(uid: uid, section: part)
        }
    }

    /// Files the mail in Drafts, Bcc header included, for a person to check and send.
    public func draft(_ mail: OutgoingMail) async throws -> DraftReceipt {
        let message = try MailCompose.message(mail, from: account)
        try await calls.enter()
        defer { calls.leave() }
        return try await imapCall {
            let folder = try await self.folder(.drafts, override: self.account.draftsFolder)
            let uid = try await self.imap.append(message.filedCopy, to: folder, flags: [.draft, .seen])
            return DraftReceipt(draftUid: uid, folder: folder)
        }
    }

    /// Sends, then files a read copy in Sent: the same bytes, with the Bcc header that the sent mail leaves out. A copy that fails, or
    /// is cancelled, doesn't undo the send; the receipt says so instead, because an error here would make a bot send the mail again.
    public func send(_ mail: OutgoingMail) async throws -> SendReceipt {
        let message = try MailCompose.message(mail, from: account)
        try await calls.enter()
        defer { calls.leave() }
        do {
            try await smtp.login(username: account.username, password: password)
            try await smtp.send(message.bytes, from: message.sender, to: message.recipients)
        } catch {
            await smtp.logout()
            throw mapped(error, host: account.smtp.host)
        }
        await smtp.logout()
        guard account.saveSentCopy else { return SendReceipt(messageId: message.messageId, savedToSent: false) }
        do {
            try await imapCall {
                let folder = try await self.folder(.sent, override: self.account.sentFolder)
                _ = try await self.imap.append(message.filedCopy, to: folder, flags: [.seen])
            }
            return SendReceipt(messageId: message.messageId, savedToSent: true)
        } catch {
            return SendReceipt(messageId: message.messageId, savedToSent: false)
        }
    }

    /// Signs in to SMTP and out again, without sending: the "test connection" check.
    public func checkSending() async throws {
        try await calls.enter()
        defer { calls.leave() }
        do {
            try await smtp.login(username: account.username, password: password)
            await smtp.logout()
        } catch {
            await smtp.logout()
            throw mapped(error, host: account.smtp.host)
        }
    }

    /// Signs out of IMAP once the calls before it are done. It waits for its turn even when cancelled, because it cannot report
    /// a cancellation and must not cut into another call.
    public func close() async {
        await calls.enterEvenIfCancelled()
        defer { calls.leave() }
        if signedIn { await imap.logout() }
        signedIn = false
    }

    private func imapCall<T>(_ body: () async throws -> T) async throws -> T {
        do {
            if !signedIn {
                try await imap.login(username: account.username, password: password)
                signedIn = true
            }
            return try await body()
        } catch {
            throw mapped(error, host: account.imap.host)
        }
    }

    /// The error in words a person can act on. A cancellation stays one, so a caller that stopped waiting isn't told the server refused.
    private func mapped(_ error: Error, host: String) -> Error {
        error is CancellationError ? error : MailEngineError.from(error, host: host, password: password)
    }

    /// The headers of the message with this UID. Only a header for that very UID counts: a server can answer with another mail
    /// (UID FETCH * means the newest), which must not be read, marked or saved in this one's name.
    private func header(uid: Int) async throws -> HeaderRecord {
        guard let header = try await imap.headers([uid]).first(where: { $0.uid == uid }) else { throw MailEngineError.messageNotFound(uid: uid) }
        return header
    }

    /// A text part as readable text: decoded by its charset, and HTML turned into plain text.
    private func text(of part: PartRecord, uid: Int) async throws -> String {
        let decoded = MailText.decode(try await imap.partData(uid: uid, section: part.section), charset: part.charset)
        return part.contentType == "text/html" ? MailText.plainText(fromHTML: decoded) : decoded
    }

    private func folder(_ role: FolderRole, override: String?) async throws -> String {
        if let override, !override.isEmpty { return override }
        if let marked = try await imap.folders().first(where: { $0.role == role }) { return marked.name }
        throw MailEngineError.folderNotFound(role: role == .drafts ? "Drafts" : "Sent")
    }
}

/// Lets a session's calls through one at a time, first come first served. An actor alone would not do: it lets the next call in at
/// every await, while a session's call has to run whole.
private final class CallQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiting: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var lastID = 0

    /// Waits for the caller's turn. A caller cancelled before its turn comes leaves the queue with a CancellationError, so a call
    /// that was given up on never starts.
    func enter() async throws {
        try await waitForTurn(cancellable: true)
        // A cancellation that comes while the turn is being handed over finds no waiter to remove, so the turn is passed on here
        // and the call does not start.
        if Task.isCancelled {
            leave()
            throw CancellationError()
        }
    }

    /// Waits for the caller's turn whether or not it is cancelled.
    func enterEvenIfCancelled() async {
        // Only the cancellation handler resumes a wait with an error, and this wait has none.
        try? await waitForTurn(cancellable: false)
    }

    /// Hands the turn to the caller who has waited longest, or frees it.
    func leave() {
        let next: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !waiting.isEmpty else {
                busy = false
                return nil
            }
            return waiting.removeFirst().continuation
        }
        next?.resume()
    }

    private func waitForTurn(cancellable: Bool) async throws {
        let id = lock.withLock {
            lastID += 1
            return lastID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Entry { case cancelled, now, queued }
                let entry: Entry = lock.withLock {
                    if cancellable, Task.isCancelled { return .cancelled }
                    if !busy {
                        busy = true
                        return .now
                    }
                    waiting.append((id, continuation))
                    return .queued
                }
                switch entry {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .now: continuation.resume()
                case .queued: break
                }
            }
        } onCancel: {
            guard cancellable else { return }
            let removed: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting.remove(at: index).continuation
            }
            removed?.resume(throwing: CancellationError())
        }
    }
}
