#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Large payloads stay out of JSON and PTYs. Both signed apps already have
/// access to the App Group that contains their authenticated socket.
public enum BrowserTransferFiles {
    public static let limit: Int64 = 8 * 1024 * 1024 * 1024

    public static func staging(root: URL, id: UUID, create: Bool) throws -> URL {
        let directory = root.appendingPathComponent("file-transfers", isDirectory: true)
        if create, mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw BrowserError("Cannot create the file-transfer directory.")
        }
        try checkDirectory(directory)
        if create {
            // Recover abandoned payloads after a crash. Live requests time out
            // after ten minutes; never touch a recent transfer or follow a link.
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                var info = stat()
                if UUID(uuidString: url.lastPathComponent) != nil, lstat(url.path, &info) == 0,
                   info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                   Date().timeIntervalSince1970 - Double(info.modified.tv_sec) > 3600 {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        let transfer = directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        if create, mkdir(transfer.path, 0o700) != 0 {
            throw BrowserError("Cannot create a unique file transfer.")
        }
        try checkDirectory(transfer)
        return transfer.appendingPathComponent("payload")
    }

    private static func checkDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw BrowserError("Unsafe file-transfer directory.")
        }
    }

    public static func openSource(_ url: URL) throws -> Int32 {
        let fd = openFile(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BrowserError("Cannot open the transfer source.") }
        do { _ = try size(fd); return fd } catch { _ = close(fd); throw error }
    }

    public static func size(_ fd: Int32) throws -> Int64 {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else {
            throw BrowserError("Transfers require a regular file up to 8 GiB.")
        }
        return Int64(info.st_size)
    }

    /// Call on a worker, with exclusive ownership of both file descriptors.
    @discardableResult public static func copy(source: Int32, destination: Int32) throws -> Int64 {
        let expected = try size(source)
        var before = stat(); guard fstat(source, &before) == 0 else { throw BrowserError("Cannot inspect transfer source.") }
        let input = FileHandle(fileDescriptor: source, closeOnDealloc: false)
        let output = FileHandle(fileDescriptor: destination, closeOnDealloc: false)
        var count: Int64 = 0
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            guard Int64(data.count) <= expected - count else { throw BrowserError("The source changed during transfer.") }
            try output.write(contentsOf: data)
            count += Int64(data.count)
        }
        var after = stat()
        guard count == expected, fstat(source, &after) == 0, after.st_size == before.st_size,
              after.modified.tv_sec == before.modified.tv_sec,
              after.modified.tv_nsec == before.modified.tv_nsec,
              after.changed.tv_sec == before.changed.tv_sec,
              after.changed.tv_nsec == before.changed.tv_nsec else {
            throw BrowserError("The source changed or the transfer was incomplete.")
        }
        try output.synchronize()
        return count
    }
}

private func openFile(_ path: String, _ flags: Int32) -> Int32 { open(path, flags) }

private extension stat {
    #if canImport(Darwin)
    var modified: timespec { st_mtimespec }
    var changed: timespec { st_ctimespec }
    #else
    var modified: timespec { st_mtim }
    var changed: timespec { st_ctim }
    #endif
}
