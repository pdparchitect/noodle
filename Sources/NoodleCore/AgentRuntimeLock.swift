import Darwin
import Foundation

/// One harness per bot, held by the harness itself.
///
/// The app's coordinator already starts one runtime per bot, but only for the
/// processes it knows about. A host that crashes or is killed leaves its
/// harness running in its own process group, and a fast relaunch can start a
/// new one before the old one has stopped. The harness child therefore takes
/// this lock before it prepares anything and keeps the descriptor open through
/// `execv`, so the kernel holds it for as long as the harness, or anything it
/// started, is alive.
public enum AgentRuntimeLock {
    public struct Refusal: LocalizedError {
        public var errorDescription: String? { "This bot is already running in another process." }
    }

    /// Returns the open descriptor. Callers must not close it before `execv`.
    ///
    /// A holder is stopped only when its process group is still led by a
    /// process working inside this bot's workspace, which is what a harness left
    /// behind looks like. Anything else is refused and never signalled.
    public static func acquire(layout: AgentStorageLayout, grace: TimeInterval = 3) throws -> Int32 {
        let path = layout.runtime.appendingPathComponent("harness.lock").path
        // The harness inherits this descriptor, so it is read-only: the bot
        // cannot rewrite which group the next start would stop.
        let descriptor = open(path, O_RDONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            if !lock(descriptor) {
                guard let group = recordedGroup(descriptor),
                      leads(group, inside: layout.workspace) else { throw Refusal() }
                guard stop(group, signal: SIGTERM, until: descriptor, within: grace)
                        || stop(group, signal: SIGKILL, until: descriptor, within: grace) else { throw Refusal() }
            }
            let writer = open(path, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
            let record = Data("\(getpgrp())\n".utf8)
            let written = writer >= 0 ? record.withUnsafeBytes { write(writer, $0.baseAddress, record.count) } : -1
            if writer >= 0 { close(writer) }
            guard written == record.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func lock(_ descriptor: Int32) -> Bool { flock(descriptor, LOCK_EX | LOCK_NB) == 0 }

    private static func recordedGroup(_ descriptor: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0,
              let group = pid_t(String(decoding: buffer[..<count], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)),
              group > 1, group != getpgrp() else { return nil }
        return group
    }

    private static func leads(_ group: pid_t, inside workspace: URL) -> Bool {
        guard getpgid(group) == group else { return false }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(group, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return false }
        let directory = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        // Foundation's symlink resolution drops /private; the kernel reports it.
        guard let resolved = realpath(workspace.path, nil) else { return false }
        let root = String(cString: resolved)
        free(resolved)
        return directory == root || directory.hasPrefix(root + "/")
    }

    private static func stop(_ group: pid_t, signal: Int32, until descriptor: Int32, within grace: TimeInterval) -> Bool {
        kill(-group, signal)
        let deadline = Date().addingTimeInterval(grace)
        repeat {
            if lock(descriptor) { return true }
            usleep(50_000)
        } while Date() < deadline
        return lock(descriptor)
    }
}
