#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The few system calls whose spelling differs between Darwin and Linux, for code that would
// otherwise name `Darwin.` to reach past a method of the same name.

package func systemOpen(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 { open(path, flags, mode) }

@discardableResult package func systemClose(_ descriptor: Int32) -> Int32 { close(descriptor) }

package extension stat {
    var modified: timespec {
        #if canImport(Darwin)
        st_mtimespec
        #else
        st_mtim
        #endif
    }

    var changed: timespec {
        #if canImport(Darwin)
        st_ctimespec
        #else
        st_ctim
        #endif
    }
}

/// Writing to a child process that has exited reports EPIPE instead of ending this one with SIGPIPE.
package enum BrokenPipe {
    package static func reportAsError(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        #else
        // Linux has no such setting for a pipe, so the process ignores SIGPIPE.
        _ = ignored
        #endif
    }

    #if !canImport(Darwin)
    private static let ignored: Void = { _ = signal(SIGPIPE, SIG_IGN) }()
    #endif
}

/// Swaps two items, on Darwin in one step, so nothing ever finds either path missing.
package func swapItems(_ first: String, _ second: String) -> Int32 {
    #if canImport(Darwin)
    renamex_np(first, second, UInt32(RENAME_SWAP))
    #else
    // Glibc's module leaves out renameat2, so this takes three steps, with a moment where
    // `second` is missing.
    let aside = second + ".swap-" + UUID().uuidString
    guard rename(second, aside) == 0 else { return -1 }
    guard rename(first, second) == 0 else { _ = rename(aside, second); return -1 }
    return rename(aside, first)
    #endif
}

/// Renames `source` to `target` in the folder open as `folder`, never replacing what is there:
/// fails with EEXIST when `target` exists, and when two take the same `source` only one succeeds.
package func renameExclusively(in folder: Int32, _ source: String, _ target: String) -> Int32 {
    #if canImport(Darwin)
    renameatx_np(folder, source, folder, target, UInt32(RENAME_EXCL))
    #else
    // Glibc's module leaves out renameat2, so a link refuses an existing target, and only the
    // one who then removes `source` has renamed it.
    guard linkat(folder, source, folder, target, 0) == 0 else { return -1 }
    guard unlinkat(folder, source, 0) == 0 else {
        let failure = errno
        _ = unlinkat(folder, target, 0)
        errno = failure
        return -1
    }
    return 0
    #endif
}

/// A folder entry's name.
package func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
    }
}

/// The current folder of a running process, as the kernel reports it.
package func currentDirectory(of process: pid_t) -> String? {
    #if canImport(Darwin)
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(process, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    #else
    return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(process)/cwd")
    #endif
}

/// Executable paths of the running processes this user can see.
package func runningExecutablePaths() -> [String] {
    #if canImport(Darwin)
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return pids.prefix(max(0, count)).compactMap { pid in
        proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }
    #else
    let processes = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
    return processes.filter { $0.allSatisfy(\.isNumber) }
        .compactMap { try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\($0)/exe") }
    #endif
}

/// The space free for what this app keeps on the volume holding `url`.
package func availableCapacity(at url: URL) throws -> Int64? {
    #if canImport(Darwin)
    try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    #else
    try url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity.map(Int64.init)
    #endif
}

package extension URLSession {
    /// The body of `request`, read only up to `limit` bytes; past it, `tooLarge` is thrown.
    /// `accept` sees the response first and throws to refuse it before any of the body is read.
    /// Linux's URLSession has no byte stream, so there the limit holds once the whole body is in.
    func data(for request: URLRequest, limit: Int, tooLarge: @autoclosure () -> Error,
              accept: (URLResponse) throws -> Void = { _ in }) async throws -> (Data, URLResponse) {
        #if canImport(Darwin)
        let (bytes, response) = try await self.bytes(for: request)
        try accept(response)
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw tooLarge() }
            data.append(byte)
        }
        return (data, response)
        #else
        let (data, response) = try await self.data(for: request)
        try accept(response)
        guard data.count <= limit else { throw tooLarge() }
        return (data, response)
        #endif
    }
}
