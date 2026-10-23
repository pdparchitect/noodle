import Foundation
import MailEngine

// Read-only check of a real mailbox. It signs in, prints the folders with their roles and the five newest
// INBOX messages as JSON, reads the newest one without marking it read and shows only sizes and counts from
// that read, and, if an SMTP host is given, signs in to SMTP without sending anything.
// The password is typed at a hidden prompt and kept only in memory.

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: mail-probe IMAP_HOST USERNAME [SMTP_HOST]\n".utf8))
    exit(2)
}
let imapHost = arguments[arguments.startIndex]
let username = arguments[arguments.startIndex + 1]
let smtpHost = arguments.count >= 3 ? arguments[arguments.startIndex + 2] : nil

var buffer = [CChar](repeating: 0, count: 1024)
guard let typed = readpassphrase("Password for \(username) (hidden, not saved): ", &buffer, buffer.count, 0) else { exit(1) }
let password = String(cString: typed)
buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
// Enter or Ctrl-D with nothing typed gives an empty string, not NULL; stop here instead of signing in with it.
guard !password.isEmpty else {
    FileHandle.standardError.write(Data("mail-probe: no password was typed\n".utf8))
    exit(1)
}

let account = MailAccount(address: username, username: username,
                          imap: MailServer(host: imapHost, port: 993, security: .tls),
                          smtp: MailServer(host: smtpHost ?? imapHost, port: 465, security: .tls))

struct Report: Encodable {
    let folders: [MailFolder]
    let newest: [MessageRow]
    /// Missing when INBOX is empty.
    let read: ReadCheck?
    let smtp: String?
}

do {
    let session = try MailSession(account: account, password: password)
    let folders = try await session.folders()
    var query = MessageQuery()
    query.limit = 5
    let newest = try await session.list(query)
    var read: ReadCheck?
    if let uid = newest.first?.uid { read = await ReadCheck.of(uid: uid, in: session) }
    var smtp: String?
    if smtpHost != nil {
        do { try await session.checkSending(); smtp = "signed in" } catch { smtp = error.localizedDescription }
    }
    await session.close()
    print(try MailJSON.encode(Report(folders: folders, newest: newest, read: read, smtp: smtp)))
} catch {
    FileHandle.standardError.write(Data("mail-probe: \(error.localizedDescription)\n".utf8))
    exit(1)
}
