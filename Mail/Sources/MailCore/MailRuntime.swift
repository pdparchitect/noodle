import Foundation
import MailBridge
import MailEngine

/// What the runtime needs from a signed-in mailbox. MailEngine's `MailSession` provides it;
/// tests use a fake.
public protocol MailboxSession: AnyObject {
    func folders() async throws -> [MailFolder]
    func list(_ query: MessageQuery) async throws -> [MessageRow]
    func read(uid: Int, folder: String, markRead: Bool) async throws -> MessageDetail
    func attachment(uid: Int, part: String, folder: String) async throws -> Data
    func close() async
}

extension MailSession: MailboxSession {}

/// Answers Noodle's and the Mail tool's requests from the mailboxes in the library. A mailbox's
/// password is read from the Keychain when its session starts and stays inside that session.
public actor MailRuntime {
    public typealias SessionFactory = @Sendable (MailAccount, String) throws -> MailboxSession
    private let library: MailboxLibrary
    private let secrets: MailSecretStorage
    private let makeSession: SessionFactory
    private var sessions: [UUID: (account: MailAccount, session: MailboxSession)] = [:]

    public init(library: MailboxLibrary, secrets: MailSecretStorage,
                makeSession: @escaping SessionFactory = { try MailSession(account: $0, password: $1) }) {
        self.library = library
        self.secrets = secrets
        self.makeSession = makeSession
    }

    /// The answer to one request. It never throws: every failure comes back as one sentence in `error`.
    /// The caller has already been checked against the socket's client list.
    public func perform(_ request: MailRequest, caller: String) async -> MailResponse {
        do {
            try request.validate()
            // An unreadable list is not an empty one: answering `[]` makes Noodle save it and treat every assigned mailbox as gone.
            if let failure = library.failure { return MailResponse(error: failure) }
            var response = MailResponse()
            if request.operation == .mailboxes {
                response.mailboxes = library.mailboxes().map(\.remote)
                return response
            }
            guard let id = request.mailboxID, let record = library.mailbox(id) else {
                throw MailError("This mailbox no longer exists in \(MailBuildIdentity.current.appName).")
            }
            let session = try session(for: record)
            let folder = request.folder ?? "INBOX"
            switch request.operation {
            case .mailboxes:
                break
            case .folders:
                let folders = try await use(id, session) { try await $0.folders() }
                response.folders = folders.map { MailFolderInfo(name: $0.name, display: MailFolderName.display($0.name), role: $0.role?.rawValue) }
            case .list, .search:
                let query = Self.query(request)
                response.messages = try await use(id, session) { try await $0.list(query) }.map(Self.row)
            case .read:
                let detail = try await use(id, session) { try await $0.read(uid: request.uid ?? 0, folder: folder, markRead: request.markRead ?? false) }
                response.message = Self.message(detail, limit: request.maxCharacters ?? MailLimits.defaultCharacters)
            case .attachment:
                let data = try await use(id, session) { try await $0.attachment(uid: request.uid ?? 0, part: request.part ?? "", folder: folder) }
                guard data.count <= MailLimits.attachmentBytes else {
                    throw MailError("This attachment is larger than 20 MB. Open it in a mail app instead.")
                }
                response.attachment = MailAttachmentData(data: data)
            }
            return response
        } catch {
            return MailResponse(error: Self.describe(error))
        }
    }

    /// Drops whatever session a mailbox has, after its settings or password changed.
    /// It signs out in the background, so a dead connection can't hold up the answer.
    public func forget(_ id: UUID) {
        guard let old = sessions.removeValue(forKey: id) else { return }
        Task { await old.session.close() }
    }

    public func shutdown() async {
        let open = sessions.values.map(\.session)
        sessions = [:]
        for session in open { await session.close() }
    }

    private func session(for record: MailboxRecord) throws -> MailboxSession {
        if let cached = sessions[record.id], cached.account == record.account { return cached.session }
        forget(record.id)
        guard let password = try secrets.password(for: record.id), !password.isEmpty else {
            throw MailError("Open \(MailBuildIdentity.current.appName) and enter the password for \(record.name).")
        }
        let session = try makeSession(record.account, password)
        sessions[record.id] = (record.account, session)
        return session
    }

    /// One engine call on `session`. A session that failed may be signed out or stale, so it is signed out and, if it is
    /// still the mailbox's session, dropped: the next call starts afresh. A newer session that replaced it meanwhile is
    /// another connection, and stays. The exception is an error that only says the request asked for something that is not
    /// there (a message or a part): the connection is fine, so it stays open and signed in for the next call. A folder that
    /// is not there is refused by the server at SELECT, which drops the session like any other refusal.
    private func use<T>(_ id: UUID, _ session: MailboxSession, _ call: (MailboxSession) async throws -> T) async throws -> T {
        do { return try await call(session) } catch {
            if (error as? MailEngineError)?.leavesSessionUsable == true { throw error }
            if sessions[id]?.session === session { sessions[id] = nil }
            Task { await session.close() }
            throw error
        }
    }

    static func query(_ request: MailRequest) -> MessageQuery {
        let filters = request.query ?? MailQuery()
        var query = MessageQuery()
        query.folder = request.folder ?? "INBOX"
        query.unreadOnly = filters.unreadOnly ?? false
        query.from = filters.from
        query.to = filters.to
        query.subject = filters.subject
        query.text = filters.text
        query.since = filters.since.flatMap(MailRequest.day)
        query.before = filters.before.flatMap(MailRequest.day)
        query.beforeUID = filters.beforeUID
        query.limit = filters.limit ?? 20
        return query
    }

    static func row(_ row: MessageRow) -> MailMessageRow {
        MailMessageRow(uid: row.uid, date: row.date.map(iso), from: row.from, subject: row.subject, seen: row.seen, attachments: row.attachments)
    }

    static func message(_ detail: MessageDetail, limit: Int) -> MailMessage {
        let truncated = detail.text.unicodeScalars.count > limit
        return MailMessage(uid: detail.uid, from: detail.from, to: detail.to, cc: detail.cc, date: detail.date.map(iso),
                           subject: detail.subject, messageId: detail.messageId,
                           text: truncated ? String(detail.text.unicodeScalars.prefix(limit)) : detail.text, truncated: truncated,
                           attachments: detail.attachments.map { MailAttachmentInfo(part: $0.part, name: $0.name, type: $0.type, size: $0.size) },
                           attachmentsOmitted: detail.attachmentsOmitted)
    }

    /// One sentence for the caller. The engine's errors never carry a password; any other error is
    /// replaced by a generic sentence, because its text could carry anything.
    static func describe(_ error: Error) -> String {
        if let error = error as? MailError { return error.message }
        if let error = error as? MailEngineError { return error.localizedDescription }
        return "\(MailBuildIdentity.current.appName) could not complete the request. Check the mailbox in \(MailBuildIdentity.current.appName)."
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
