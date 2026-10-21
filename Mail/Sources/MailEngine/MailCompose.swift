import Foundation
import SwiftMail

/// A mail ready to go out: its bytes, and who sends and gets it.
struct ComposedMail {
    /// The message exactly as it goes over SMTP: lines that end in CRLF, quoted-printable text, base64 files, and no Bcc header.
    let bytes: Data
    /// The account, for MAIL FROM.
    let sender: EmailAddress
    /// To, Cc and Bcc, for RCPT TO.
    let recipients: [EmailAddress]
    /// Named only in the copies filed in Drafts and Sent.
    let bcc: [EmailAddress]
    let messageId: String

    /// What is filed in Drafts or Sent: the same bytes with a Bcc header on top, so a person who sends the draft from webmail
    /// still reaches the Bcc recipients, and Sent shows who got a blind copy. It never goes over SMTP, where every recipient would see it.
    var filedCopy: Data {
        guard !bcc.isEmpty else { return bytes }
        return Data("Bcc: \(bcc.map(\.address).joined(separator: ", "))\r\n".utf8) + bytes
    }
}

enum MailCompose {
    /// A SwiftMail message from what a bot asked for. Every header value stays on one line, every line break in the body is CRLF,
    /// and the Message-ID is fixed here so the sent mail and its Sent copy match.
    static func email(_ mail: OutgoingMail, from account: MailAccount) throws -> Email {
        let to = try mail.to.map(address)
        let cc = try mail.cc.map(address)
        let bcc = try mail.bcc.map(address)
        guard !(to.isEmpty && cc.isEmpty && bcc.isEmpty) else { throw MailEngineError.noRecipients }
        let attachments = mail.attachments.map {
            Attachment(filename: MailText.singleLine($0.filename), mimeType: MailText.singleLine($0.mimeType), data: $0.data)
        }
        var email = Email(sender: EmailAddress(name: account.displayName.map(MailText.singleLine), address: account.address), recipients: to,
                          ccRecipients: cc, bccRecipients: bcc, subject: MailText.singleLine(mail.subject),
                          textBody: MailText.crlfLineBreaks(mail.body), attachments: attachments.isEmpty ? nil : attachments)
        let domain = account.address.split(separator: "@").last.map(String.init) ?? "localhost"
        email.messageID = MessageID.generate(domain: domain)
        if let original = mail.inReplyTo.map(firstMessageID), !original.isEmpty {
            email.additionalHeaders = ["In-Reply-To": original, "References": original]
        }
        return email
    }

    /// The bytes and envelope for a mail, built once so that SMTP, Drafts and Sent all get the same message. SwiftMail builds the
    /// bytes with 8BITMIME off whatever the server offers: its 8-bit path counts characters instead of octets and lets lone CR and LF
    /// through, while quoted-printable text and base64 files are short CRLF lines of plain ASCII.
    static func message(_ mail: OutgoingMail, from account: MailAccount) throws -> ComposedMail {
        let email = try email(mail, from: account)
        // Bcc recipients belong in the envelope only. SwiftMail writes no Bcc header; clearing them keeps it that way.
        var visible = email
        visible.bccRecipients = []
        return ComposedMail(bytes: Data(visible.constructContent(use8BitMIME: false).utf8), sender: email.sender,
                            recipients: email.recipients + email.ccRecipients + email.bccRecipients, bcc: email.bccRecipients,
                            messageId: email.messageID.map { "\($0)" } ?? "")
    }

    private static func address(_ raw: String) throws -> EmailAddress {
        let text = MailText.singleLine(raw)
        guard text.contains("@"), let parsed = EmailAddress(text) else { throw MailEngineError.invalidAddress(raw) }
        // The parser decodes an encoded word in the display name, so the name can hold a line break that the flattening above never saw.
        return EmailAddress(name: parsed.name.map(MailText.singleLine), address: parsed.address)
    }

    /// Only the first "<…>" token survives, so anything smuggled after a line break is dropped.
    private static func firstMessageID(_ raw: String) -> String {
        let firstLine = raw.components(separatedBy: CharacterSet.newlines).first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "<"), let close = trimmed[open...].firstIndex(of: ">") else { return trimmed }
        return String(trimmed[open...close])
    }
}
