import Foundation
import MailCore

/// Passwords in memory, so tests never touch the person's Keychain.
final class MemorySecrets: MailSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    func password(for mailbox: UUID) throws -> String? { lock.withLock { values[mailbox] } }
    func hasPassword(for mailbox: UUID) -> Bool { lock.withLock { values[mailbox] != nil } }
    func setPassword(_ password: String?, for mailbox: UUID) throws {
        lock.withLock { values[mailbox] = password.flatMap { $0.isEmpty ? nil : $0 } }
    }
}
