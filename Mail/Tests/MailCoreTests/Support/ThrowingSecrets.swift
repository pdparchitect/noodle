import Foundation
import MailCore

/// A Keychain that refuses every read and write, as a locked one does.
struct ThrowingSecrets: MailSecretStorage {
    let failure: Error
    func password(for mailbox: UUID) throws -> String? { throw failure }
    func hasPassword(for mailbox: UUID) -> Bool { false }
    func setPassword(_ password: String?, for mailbox: UUID) throws { throw failure }
}
