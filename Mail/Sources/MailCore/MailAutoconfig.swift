import Foundation
import MailEngine

/// How a provider's settings say the username is formed from the address.
public enum MailUsername: Equatable, Sendable {
    case address, localPart, fixed(String)
}

/// One provider's IMAP and SMTP servers, ready to fill in the mailbox form.
public struct MailServerSettings: Equatable, Sendable {
    public var imap: MailServer
    public var smtp: MailServer
    public var username: MailUsername
    public init(imap: MailServer, smtp: MailServer, username: MailUsername) {
        self.imap = imap; self.smtp = smtp; self.username = username
    }
}

/// Thunderbird's autoconfig format (config-v1.1.xml), served by domains themselves and by Mozilla's ISPDB.
/// Only IMAP and SMTP with a password over TLS or STARTTLS are taken: never plain text, never POP3.
public enum MailAutoconfig {
    public enum Result: Equatable, Sendable { case settings(MailServerSettings), oauthOnly, unusable }

    public static func parse(_ data: Data, domain: String) -> Result {
        let reader = Reader()
        // XMLParser's defaults resolve no external entities; they stay.
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return .unusable }
        let incoming = reader.entries.filter { !$0.outgoing && $0.type == "imap" }
        let outgoing = reader.entries.filter { $0.outgoing && $0.type == "smtp" }
        let imap = incoming.lazy.filter(\.allowsPassword).compactMap { entry in entry.server(domain: domain).map { (entry, $0) } }.first
        let smtp = outgoing.lazy.filter(\.allowsPassword).compactMap { $0.server(domain: domain) }.first
        if let imap, let smtp {
            return .settings(MailServerSettings(imap: imap.1, smtp: smtp, username: username(imap.0.username)))
        }
        return (incoming + outgoing).contains { $0.offersOAuth && !$0.allowsPassword } ? .oauthOnly : .unusable
    }

    /// A DNS host name with at least two labels: letters, digits and inner hyphens only, and a last label that
    /// starts with a letter, as every top-level domain does (xn-- ones too). That keeps out number-only
    /// names such as 10.0.0.5, 127.1, 0x7f.1 and 127.0.0.0x1, which the system resolver reads as IP addresses.
    public static func isHostName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return host.utf8.count <= 253 && labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        } && labels.last?.first.map { $0.isASCII && $0.isLetter } == true
    }

    static func username(_ raw: String) -> MailUsername {
        switch raw {
        case "", "%EMAILADDRESS%": return .address
        case "%EMAILLOCALPART%": return .localPart
        default: return raw.contains("%") || raw.utf8.count > 254 || raw.contains(where: \.isNewline) ? .address : .fixed(raw)
        }
    }

    struct Entry {
        let outgoing: Bool
        let type: String
        var hostname = "", port = "", socketType = "", username = ""
        var authentications: [String] = []

        /// No authentication element at all means a password, as Thunderbird reads it.
        var allowsPassword: Bool {
            authentications.isEmpty || authentications.contains { ["password-cleartext", "password-encrypted", "plain", "secure"].contains($0) }
        }
        var offersOAuth: Bool { authentications.contains("OAuth2") }

        func server(domain: String) -> MailServer? {
            let security: MailSecurity
            switch socketType.uppercased() {
            case "SSL", "TLS": security = .tls
            case "STARTTLS": security = .startTLS
            default: return nil
            }
            let host = hostname.replacingOccurrences(of: "%EMAILDOMAIN%", with: domain).lowercased()
            guard MailAutoconfig.isHostName(host) else { return nil }
            let standard = outgoing ? (security == .tls ? 465 : 587) : (security == .tls ? 993 : 143)
            guard let number = port.isEmpty ? standard : Int(port), (1...65_535).contains(number) else { return nil }
            return MailServer(host: host, port: number, security: security)
        }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var current: Entry?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if name == "incomingServer" || name == "outgoingServer" {
                current = Entry(outgoing: name == "outgoingServer", type: (attributes["type"] ?? "").lowercased())
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            switch name {
            case "incomingServer", "outgoingServer":
                if let current { entries.append(current) }
                current = nil
            case "hostname": current?.hostname = value
            case "port": current?.port = value
            case "socketType": current?.socketType = value
            case "username": current?.username = value
            case "authentication": current?.authentications.append(value)
            default: break
            }
        }
    }
}
