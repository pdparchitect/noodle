import Foundation
import SwiftMail

/// How the connection to a mail server is protected.
public enum MailSecurity: String, Codable, Sendable {
    /// Encrypted from the first byte (IMAP 993, SMTP 465).
    case tls
    /// Upgraded to encryption before signing in (IMAP 143, SMTP 587).
    case startTLS
    /// Unencrypted; only for test servers on this Mac.
    case plainText
}

/// One IMAP or SMTP server.
public struct MailServer: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var security: MailSecurity

    public init(host: String, port: Int, security: MailSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }

    /// SwiftMail's transport mode. Always explicit: SwiftMail's automatic mode stays unencrypted on 587 or 143 when a server doesn't offer STARTTLS.
    public func transportSecurity() throws -> MailTransportSecurity {
        switch security {
        case .tls: return .implicitTLS
        case .startTLS: return .startTLS
        case .plainText:
            guard ["127.0.0.1", "::1", "localhost"].contains(host.lowercased()) else { throw MailEngineError.insecureServer(host: host) }
            return .plainText
        }
    }
}

/// A mailbox and how to reach it. The password is not part of it; the app keeps that in the Keychain.
public struct MailAccount: Codable, Equatable, Sendable {
    public var address: String
    public var displayName: String?
    public var username: String
    public var imap: MailServer
    public var smtp: MailServer
    /// The Drafts folder to use when the server doesn't mark one: the server's raw name, exactly as `MailSession.folders()` returns it,
    /// which is modified UTF-7 for anything outside ASCII (Seznam's "Rozepsané" is "Rozepsan&AOk-").
    public var draftsFolder: String?
    /// The Sent folder to use when the server doesn't mark one, by its raw name in the same way (Seznam's "Odeslané" is "Odeslan&AOk-").
    public var sentFolder: String?
    /// False for providers that file sent mail themselves (Gmail), so it isn't stored twice.
    public var saveSentCopy: Bool

    public init(address: String, displayName: String? = nil, username: String, imap: MailServer, smtp: MailServer,
                draftsFolder: String? = nil, sentFolder: String? = nil, saveSentCopy: Bool = true) {
        self.address = address
        self.displayName = displayName
        self.username = username
        self.imap = imap
        self.smtp = smtp
        self.draftsFolder = draftsFolder
        self.sentFolder = sentFolder
        self.saveSentCopy = saveSentCopy
    }
}
