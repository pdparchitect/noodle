import Foundation
import MailBridge
import MailEngine

/// The mailbox form in Noodle Mail: what a person types, checked before it is saved.
public struct MailboxDraft: Equatable, Sendable {
    public var name = ""
    /// A username Find Servers made from the local part follows a corrected address, as long as the person hasn't changed it.
    public var address = "" {
        didSet {
            guard followsLocalPart, username == autoFilledUsername else { return }
            username = Self.localPart(of: address)
            autoFilledUsername = username
        }
    }
    /// Empty means the address, which most providers sign in with.
    public var username = ""
    public var imapHost = ""
    public var imapPort = 993
    public var imapSecurity = MailSecurity.tls
    public var smtpHost = ""
    public var smtpPort = 465
    public var smtpSecurity = MailSecurity.tls
    /// What the last Find Servers wrote into `username`, so a corrected address can replace it again. Not part of the
    /// form and never saved.
    private(set) var autoFilledUsername: String?
    /// Whether that username is the address's local part, the one rule that depends on the address.
    private var followsLocalPart = false

    public init() {}
    public init(_ record: MailboxRecord) {
        name = record.name
        address = record.account.address
        username = record.account.username == record.account.address ? "" : record.account.username
        imapHost = record.account.imap.host; imapPort = record.account.imap.port; imapSecurity = record.account.imap.security
        smtpHost = record.account.smtp.host; smtpPort = record.account.smtp.port; smtpSecurity = record.account.smtp.security
    }

    /// Fills in the servers Find Servers found. The name, address and password stay as typed, and so does a
    /// username that differs from what the default or an earlier Find Servers would have put there: only those
    /// values (empty, the address, the local part, what the last Find Servers wrote) are replaced.
    public mutating func apply(_ settings: MailServerSettings) {
        imapHost = settings.imap.host; imapPort = settings.imap.port; imapSecurity = settings.imap.security
        smtpHost = settings.smtp.host; smtpPort = settings.smtp.port; smtpSecurity = settings.smtp.security
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let localPart = address.lastIndex(of: "@").map { String(address[..<$0]) }
        let typed = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard typed.isEmpty || typed == address.lowercased() || typed == localPart?.lowercased()
                || typed == autoFilledUsername?.lowercased() else { return }
        switch settings.username {
        case .address: username = ""
        case .localPart: username = localPart ?? ""
        case .fixed(let value): username = value
        }
        autoFilledUsername = username.isEmpty ? nil : username
        followsLocalPart = settings.username == .localPart && autoFilledUsername != nil
    }

    /// What comes before the last "@", trimmed; all of it while no "@" has been typed yet.
    private static func localPart(of address: String) -> String {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.lastIndex(of: "@").map { String(address[..<$0]) } ?? address
    }

    /// Applies what Find Servers answered, if it found servers, and returns the sentence to show for it.
    public mutating func apply(_ result: MailServerLookupResult) -> String {
        if case .found(let settings, _, _) = result { apply(settings) }
        return result.message
    }

    /// Applies a lookup's answer only if the address still has the domain that was looked up; otherwise
    /// the person changed it meanwhile, so nothing changes and there is nothing to say.
    public mutating func apply(_ result: MailServerLookupResult, lookedUp address: String) -> String? {
        guard MailServerLookup.domain(of: self.address) == MailServerLookup.domain(of: address) else { return nil }
        return apply(result)
    }

    /// The mailbox to save, or the first problem in words a person can act on. Settings the form
    /// doesn't show (display name, folder overrides, saveSentCopy) are kept from `existing`.
    public func record(id: UUID, keeping existing: MailboxRecord? = nil) throws -> MailboxRecord {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw MailError("Give the mailbox a name of up to 100 characters.") }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), address.utf8.count <= 254,
              !address.contains(where: { $0.isWhitespace }) else { throw MailError("Enter the mailbox's e-mail address.") }
        guard username.utf8.count <= 254 else { throw MailError("The username is too long.") }
        guard !username.contains(where: { $0.isNewline }) else { throw MailError("Enter the username on one line.") }
        var account = MailAccount(address: address, username: username.isEmpty ? address : username,
                                  imap: try server(imapHost, imapPort, imapSecurity, "IMAP"),
                                  smtp: try server(smtpHost, smtpPort, smtpSecurity, "SMTP"))
        if let existing {
            account.displayName = existing.account.displayName
            account.draftsFolder = existing.account.draftsFolder
            account.sentFolder = existing.account.sentFolder
            account.saveSentCopy = existing.account.saveSentCopy
        }
        return MailboxRecord(id: id, name: name, account: account)
    }

    private func server(_ host: String, _ port: Int, _ security: MailSecurity, _ kind: String) throws -> MailServer {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.utf8.count <= 253,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":") }) else {
            throw MailError("Enter the \(kind) server's host name, such as \(kind == "IMAP" ? "imap" : "smtp").example.com.")
        }
        guard (1...65_535).contains(port) else { throw MailError("The \(kind) port must be 1 to 65535.") }
        let server = MailServer(host: host, port: port, security: security)
        // The engine refuses plain text to anything but this Mac, before any password is sent.
        do { _ = try server.transportSecurity() } catch { throw MailError("\(kind): \(error.localizedDescription)") }
        return server
    }
}
