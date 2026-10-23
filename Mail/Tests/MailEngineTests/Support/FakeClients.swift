import Foundation
@testable import MailEngine
import SwiftMail

final class FakeIMAP: IMAPClient {
    var folderList: [MailFolder] = [MailFolder(name: "INBOX", role: .inbox)]
    var records: [HeaderRecord] = []
    var partBytes: [String: Data] = [:]            // key "uid:section"
    var ignoresAskedUIDs = false                   // answers every header request with all records, as a server answers `*` with its newest mail
    var loginError: Error?
    var appendError: Error?
    private(set) var selected: [String] = []
    private(set) var searched: [[SearchTerm]] = []
    private(set) var seen: [Int] = []
    private(set) var appended: [(message: Data, folder: String, flags: [Flag])] = []
    private(set) var logins = 0

    func login(username: String, password: String) async throws {
        if let loginError { throw loginError }
        logins += 1
    }
    func folders() async throws -> [MailFolder] { folderList }
    func select(_ folder: String) async throws { selected.append(folder) }
    func search(_ terms: [SearchTerm]) async throws -> [Int] { searched.append(terms); return records.map(\.uid).sorted() }
    func headers(_ uids: [Int]) async throws -> [HeaderRecord] { ignoresAskedUIDs ? records : records.filter { uids.contains($0.uid) } }
    func partData(uid: Int, section: String) async throws -> Data {
        guard let data = partBytes["\(uid):\(section)"] else { throw MailEngineError.partNotFound(uid: uid, part: section) }
        return data
    }
    func markSeen(uid: Int) async throws { seen.append(uid) }
    func append(_ message: Data, to folder: String, flags: [Flag]) async throws -> Int? {
        if let appendError { throw appendError }
        appended.append((message, folder, flags))
        return 900 + appended.count
    }
    func logout() async {}

    /// The bytes of each APPEND.
    var appendedMessages: [Data] { appended.map(\.message) }
}

final class FakeSMTP: SMTPClient {
    var loginError: Error?
    var sendError: Error?
    private(set) var sent: [(message: Data, sender: EmailAddress, recipients: [EmailAddress])] = []
    private(set) var logouts = 0

    func login(username: String, password: String) async throws {
        if let loginError { throw loginError }
    }
    func send(_ message: Data, from sender: EmailAddress, to recipients: [EmailAddress]) async throws {
        if let sendError { throw sendError }
        sent.append((message, sender, recipients))
    }
    func logout() async { logouts += 1 }

    /// What each send put on the wire, and the RCPT TO addresses.
    var sentMessages: [(message: Data, recipients: [EmailAddress])] { sent.map { ($0.message, $0.recipients) } }
}

/// What reached the fake servers, in order, for IMAP and SMTP alike.
final class ServerLog {
    var entries: [String] = []
}

/// An IMAP fake with one selected folder per connection, as a real server has, that logs every request and can hold the SELECT of
/// one folder until the test lets it go. Signing in hands the turn to other tasks, as a network round trip does.
final class PausingIMAP: IMAPClient {
    private let log: ServerLog
    private var selected = ""
    private var held: CheckedContinuation<Void, Never>?
    /// The folder whose SELECT waits for `release()`.
    var holdSelectOf: String?

    init(log: ServerLog) { self.log = log }

    func login(username: String, password: String) async throws {
        log.entries.append("LOGIN")
        await Task.yield()
    }
    func folders() async throws -> [MailFolder] {
        log.entries.append("LIST")
        return [MailFolder(name: "INBOX", role: .inbox), MailFolder(name: "Drafts", role: .drafts), MailFolder(name: "Sent", role: .sent)]
    }
    func select(_ folder: String) async throws {
        selected = folder
        log.entries.append("SELECT \(folder)")
        if folder == holdSelectOf { await withCheckedContinuation { held = $0 } }
    }
    func search(_ terms: [SearchTerm]) async throws -> [Int] {
        log.entries.append("SEARCH in \(selected)")
        return [1]
    }
    func headers(_ uids: [Int]) async throws -> [HeaderRecord] {
        log.entries.append("FETCH in \(selected)")
        return [HeaderRecord.sample(uid: 1, subject: "mail from \(selected)")]
    }
    func partData(uid: Int, section: String) async throws -> Data {
        log.entries.append("BODY in \(selected)")
        return Data("text from \(selected)".utf8)
    }
    func markSeen(uid: Int) async throws { log.entries.append("STORE in \(selected)") }
    func append(_ message: Data, to folder: String, flags: [Flag]) async throws -> Int? {
        log.entries.append("APPEND to \(folder)")
        return nil
    }
    func logout() async { log.entries.append("LOGOUT") }

    /// Lets the held SELECT finish.
    func release() {
        held?.resume()
        held = nil
    }
}

/// An SMTP fake that only logs, into the same log as the IMAP fake.
final class LoggingSMTP: SMTPClient {
    private let log: ServerLog

    init(log: ServerLog) { self.log = log }

    func login(username: String, password: String) async throws { log.entries.append("SMTP LOGIN") }
    func send(_ message: Data, from sender: EmailAddress, to recipients: [EmailAddress]) async throws { log.entries.append("SMTP SEND") }
    func logout() async { log.entries.append("SMTP LOGOUT") }
}

extension HeaderRecord {
    static func sample(uid: Int, subject: String, parts: [PartRecord] = [PartRecord(section: "1", contentType: "text/plain", charset: "utf-8", disposition: nil, filename: nil, size: 10)]) -> HeaderRecord {
        HeaderRecord(uid: uid, date: Date(timeIntervalSince1970: 1_790_755_200 + Double(uid)), from: "Ada <ada@example.com>",
                     to: ["borek@mail.example.org"], cc: [], subject: subject, messageId: "<\(uid)@example.com>", seen: uid % 2 == 0, parts: parts)
    }
}
