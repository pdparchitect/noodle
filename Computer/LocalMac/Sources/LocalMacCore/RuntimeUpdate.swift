import Foundation
import Darwin

/// Publishes an account-owned runtime at a stable path. Validation must check
/// both the signature and the expected signing identity, and return its CDHash.
/// An atomic exchange keeps the previous bundle available until validation of
/// the published copy succeeds. The fixed staging name also permits recovery
/// after interruption, without modifying the account's other applications.
public enum LocalMacRuntimeUpdate {
    public static func install(source: URL, destination: URL,
                               validate: (URL) throws -> Data) throws {
        try install(source: source, destination: destination, validate: validate, publish: exchange)
    }

    static func install(source: URL, destination: URL, validate: (URL) throws -> Data,
                        publish: (URL, URL, Bool) throws -> Void) throws {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".noodle-desktop-update.app")
        let lockURL = directory.appendingPathComponent(".noodle-desktop-update.lock")
        guard source.standardizedFileURL != destination.standardizedFileURL,
              directory.resolvingSymlinksInPath().path == directory.path else {
            throw LocalMacError("The desktop helper update path is invalid.")
        }
        let expected = try validate(source)
        let lock = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw LocalMacError("Cannot lock the desktop helper for updating.") }
        defer { Darwin.close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw LocalMacError("The desktop helper is already updating, or its update lock is invalid. Retry Start.")
        }
        defer { flock(lock, LOCK_UN) }
        func exists(_ url: URL) throws -> Bool {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { return false }
                throw LocalMacError("Cannot inspect the account's desktop helper.")
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                throw LocalMacError("The desktop helper update requires account-owned folders without symbolic links.")
            }
            return true
        }
        var installed = try exists(destination)
        if try exists(staging) {
            // An interrupted exchange leaves the old bundle at staging. Restore
            // it if publication was damaged; never execute an unverified copy.
            if installed, (try? validate(destination)) == nil, (try? validate(staging)) != nil {
                try exchange(staging, destination, true)
            }
            try manager.removeItem(at: staging)
        }
        if installed, (try? validate(destination)) == expected { return }
        // A damaged existing copy is repairable from the verified source. It
        // does not have to pass signature verification to be replaced.
        do {
            try manager.copyItem(at: source, to: staging)
            guard try validate(staging) == expected else { throw LocalMacError("The staged desktop helper changed during its update.") }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        installed = try exists(destination)
        do { try publish(staging, destination, installed) }
        catch { try? manager.removeItem(at: staging); throw error }
        do {
            guard try validate(destination) == expected else { throw LocalMacError("The published desktop helper does not match this update.") }
        } catch {
            if installed {
                do { try exchange(staging, destination, true) }
                catch { throw LocalMacError("Desktop helper recovery was interrupted. Retry Start to repair it; the account has been retained.") }
            } else {
                try? manager.removeItem(at: destination)
            }
            try? manager.removeItem(at: staging)
            throw error
        }
        // After exchange staging holds the previous copy. A cleanup failure is
        // harmless and is handled on the next start, without rejecting a good update.
        try? manager.removeItem(at: staging)
    }

    private static func exchange(_ source: URL, _ destination: URL, _ exists: Bool) throws {
        let flags = UInt32(exists ? RENAME_SWAP : RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, flags) == 0 else {
            throw LocalMacError("Cannot publish the desktop helper update. The previous copy has been retained.")
        }
    }
}
