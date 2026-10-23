import Foundation
import SwiftMail

/// What can go wrong with a mailbox, in words a person can act on. Never carries a password.
public enum MailEngineError: Error, Equatable, Sendable {
    case insecureServer(host: String)
    case invalidAddress(String)
    case noRecipients
    case authenticationFailed(host: String)
    case cannotConnect(host: String)
    case secureConnectionFailed(host: String)
    case timedOut(host: String)
    case folderNotFound(role: String)
    case messageNotFound(uid: Int)
    case partNotFound(uid: Int, part: String)
    case serverRejected(String)
    case sendOutcomeUnknown(host: String)
    case recipientRejected(String)

    /// Whether the signed-in session can serve the next request after this error. A missing message or part, or no folder
    /// marked as Drafts or Sent when a draft or a sent copy is filed, only says the request asked for something that is not
    /// there; every other case may mean a broken or stale connection. A folder name the server doesn't know is refused at
    /// SELECT and arrives as `serverRejected`, so it drops the session too. No `default`, so a new case must be decided here.
    public var leavesSessionUsable: Bool {
        switch self {
        case .folderNotFound, .messageNotFound, .partNotFound:
            return true
        case .insecureServer, .invalidAddress, .noRecipients, .authenticationFailed, .cannotConnect, .secureConnectionFailed,
             .timedOut, .serverRejected, .sendOutcomeUnknown, .recipientRejected:
            return false
        }
    }

    /// Maps SwiftMail and network errors. Anything unrecognised becomes `serverRejected` with the password blanked out.
    static func from(_ error: Error, host: String, password: String) -> MailEngineError {
        if let engine = error as? MailEngineError { return engine }
        if let imap = error as? IMAPError {
            switch imap {
            case .loginFailed, .authFailed: return .authenticationFailed(host: host)
            case .timeout: return .timedOut(host: host)
            case .connectionFailed, .greetingFailed: return .cannotConnect(host: host)
            case .commandFailed(let reason), .fetchFailed(let reason), .selectFailed(let reason), .storeFailed(let reason):
                return .serverRejected(scrub(reason, password: password))
            default: break
            }
        }
        if let smtp = error as? SMTPError {
            switch smtp {
            case .authenticationFailed: return .authenticationFailed(host: host)
            case .tlsFailed: return .secureConnectionFailed(host: host)
            case .connectionFailed(let reason): return reason.localizedCaseInsensitiveContains("timeout") ? .timedOut(host: host) : .cannotConnect(host: host)
            case .sendFailed(let reason), .commandFailed(let reason): return .serverRejected(scrub(reason, password: password))
            // SwiftMail's send-time address check is stricter than our compose-time parse (ada@localhost passes ours), so report an address problem, not a server refusal.
            // Its reason is a sentence ("Invalid recipient address: ada@localhost"); carry just the address. Blank the password first so it can never be cut in two.
            case .invalidEmailAddress(let reason): return .invalidAddress(addressAtEnd(of: scrub(reason, password: password)))
            default: break
            }
        }
        // Once MAIL FROM is out, SwiftMail throws this for every send failure. An unknown outcome comes first: the mail may already be delivered, and anything less alarming invites a second send.
        if let sent = error as? SMTPSendError {
            if sent.retryDisposition == .unsafeToRetry { return .sendOutcomeUnknown(host: host) }
            if let recipient = sent.rejectedRecipient { return .recipientRejected(scrub(recipient.address, password: password)) }
            return .serverRejected(scrub(sent.description, password: password))
        }
        if let folder = error as? UndefinedFolderError { return .folderNotFound(role: role(of: folder)) }
        // NIO's own errors arrive unwrapped; match by type name so the engine needn't link NIO directly.
        let typeName = String(reflecting: type(of: error))
        if typeName.contains("NIOSSL") { return .secureConnectionFailed(host: host) }
        if typeName.contains("NIOConnectionError") || typeName.contains("IOError") { return .cannotConnect(host: host) }
        // Without NIO the engine can't name ChannelError's cases: the timeout, which carries a value, is told by its case label, and
        // the cases that mean the connection dropped by NIO's fixed wording. Every other case falls through with its own words.
        if typeName.contains("ChannelError") {
            if Mirror(reflecting: error).children.first?.label == "connectTimeout" { return .timedOut(host: host) }
            if droppedConnection.contains(String(describing: error)) { return .cannotConnect(host: host) }
        }
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return .serverRejected(scrub(text, password: password))
    }

    /// NIO's descriptions of ChannelError's eof, ioOnClosedChannel, alreadyClosed, inputClosed and outputClosed.
    private static let droppedConnection: Set<String> = ["End of file", "I/O on closed channel", "Already closed", "Input closed", "Output closed"]

    private static func role(of folder: UndefinedFolderError) -> String {
        switch folder {
        case .inbox: return "Inbox"
        case .trash: return "Trash"
        case .archive: return "Archive"
        case .sent: return "Sent"
        case .drafts: return "Drafts"
        case .junk: return "Junk"
        @unknown default: return "a special"
        }
    }

    /// The part after the last ": ", trimmed; the whole text when there is no such part.
    private static func addressAtEnd(of reason: String) -> String {
        guard let colon = reason.range(of: ": ", options: .backwards) else { return reason }
        let tail = reason[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? reason : tail
    }

    /// Blanks the password out, both as typed and as an IMAP quoted string (`"` and `\` escaped with `\`), the form a server that
    /// echoes the LOGIN arguments gives back. The quoted form goes first, because it is the longer one.
    private static func scrub(_ text: String, password: String) -> String {
        guard !password.isEmpty else { return text }
        let quoted = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return text.replacingOccurrences(of: quoted, with: "•••").replacingOccurrences(of: password, with: "•••")
    }
}

extension MailEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .insecureServer(let host): return "\(host) is set to plain text. Use TLS or STARTTLS; plain text is only for test servers on this Mac."
        case .invalidAddress(let raw): return "\"\(raw)\" is not an e-mail address."
        case .noRecipients: return "The mail has no recipients."
        case .authenticationFailed(let host): return "\(host) refused the sign-in. Check the username and password (an app password if two-factor login is on)."
        case .cannotConnect(let host): return "Could not connect to \(host). Check the server name and port, and the internet connection."
        case .secureConnectionFailed(let host): return "The encrypted connection to \(host) failed. Check the port and security setting."
        case .timedOut(let host): return "\(host) did not answer in time."
        case .folderNotFound(let role): return "This mailbox has no folder marked as \(role). Set the \(role) folder in the mailbox settings."
        case .messageNotFound(let uid): return "Message \(uid) is not in this folder."
        case .partNotFound(let uid, let part): return "Message \(uid) has no part \(part)."
        case .serverRejected(let reason): return "The server refused: \(reason)"
        // Not "check the Sent folder": the copy is filed only after a confirmed send, so an empty Sent folder would invite a second send.
        case .sendOutcomeUnknown(let host): return "\(host) stopped answering after the mail was handed over, so it may have been sent. Do not send it again until the recipient or the person in charge confirms it did not arrive."
        case .recipientRejected(let address): return "The server refused the recipient \(address)."
        }
    }
}
