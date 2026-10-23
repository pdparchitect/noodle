import Foundation
import MailBridge
import MailEngine

/// A mailbox a person added to Noodle Mail. Its password is in the Keychain, never here.
public struct MailboxRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var account: MailAccount

    public init(id: UUID = UUID(), name: String, account: MailAccount) {
        self.id = id
        self.name = name
        self.account = account
    }

    /// What Noodle and bots may know about it.
    public var remote: RemoteMailbox { RemoteMailbox(id: id, name: name, address: account.address) }
}

/// The mailboxes, in `mailboxes.json` in Noodle Mail's Application Support, which the sandbox puts inside
/// the app's own container. A list it can't read is reported and left alone, never overwritten.
public final class MailboxLibrary: @unchecked Sendable {
    private struct Archive: Codable {
        var version = 1
        var mailboxes: [MailboxRecord] = []
    }
    public static let limit = 100
    public let root: URL
    private let lock = NSLock()
    private var archive = Archive()
    private var problem: String?

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NoodleMail")
        reload()
    }

    /// Why the list couldn't be read. While set, nothing is saved.
    public var failure: String? { lock.withLock { problem } }
    private var file: URL { root.appendingPathComponent("mailboxes.json") }

    public func reload() {
        lock.withLock {
            // A list from a newer version needs that version; reopening this one can't help.
            var newer = false
            do {
                guard FileManager.default.fileExists(atPath: file.path) else { archive = Archive(); problem = nil; return }
                let data = try Data(contentsOf: file)
                guard data.count <= 1_048_576 else { throw MailError("The file is too large.") }
                let decoded = try JSONDecoder().decode(Archive.self, from: data)
                guard decoded.version == 1 else { newer = true; throw MailError("It comes from a newer Noodle Mail.") }
                archive = decoded
                problem = nil
            } catch {
                archive = Archive()
                problem = "Noodle Mail could not read its mailbox list, so it was left unchanged. \(error.localizedDescription) "
                    + (newer ? "Update Noodle Mail." : "Quit and reopen Noodle Mail. If it stays, check the mailbox list file's permissions.")
            }
        }
    }
    public func mailboxes() -> [MailboxRecord] { lock.withLock { archive.mailboxes } }
    public func mailbox(_ id: UUID) -> MailboxRecord? { lock.withLock { archive.mailboxes.first { $0.id == id } } }

    /// Adds the mailbox, or replaces the one with its id.
    public func save(_ record: MailboxRecord) throws {
        try change { archive in
            if let index = archive.mailboxes.firstIndex(where: { $0.id == record.id }) {
                archive.mailboxes[index] = record
            } else {
                guard archive.mailboxes.count < Self.limit else { throw MailError("Noodle Mail holds at most \(Self.limit) mailboxes.") }
                archive.mailboxes.append(record)
            }
        }
    }
    public func remove(_ id: UUID) throws {
        try change { $0.mailboxes.removeAll { $0.id == id } }
    }

    private func change(_ edit: (inout Archive) throws -> Void) throws {
        try lock.withLock {
            if let problem { throw MailError(problem) }
            var next = archive
            try edit(&next)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(next).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            archive = next
        }
    }
}
