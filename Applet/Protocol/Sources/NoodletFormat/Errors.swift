import Darwin
import Foundation

public struct AppletError: Error, LocalizedError, Sendable {
    public let message: String
    public let unavailable: Bool
    public let code: String?
    public init(_ message: String, unavailable: Bool = false, code: String? = nil) {
        self.message = message
        self.unavailable = unavailable
        self.code = code
    }
    public var errorDescription: String? { message }
}

/// Paths a noodlet names inside its own folder or data: relative, and never leaving it.
public enum NoodletPath {
    public static func validate(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), path.utf8.count < 2048
        else {
            throw AppletError("Unsafe relative path: \(path.prefix(100))")
        }
    }

    /// `relative` inside `root`, refusing a path that leaves it or passes through a link.
    public static func child(_ relative: String, in root: URL) throws -> URL {
        try validate(relative)
        var current = root
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component))
            if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw AppletError("Symlinks are not allowed inside noodlets: \(relative)")
            }
        }
        return current
    }

    /// Opens `relative` inside `root` to read it. `root` is the folder as it was when someone
    /// checked whose it is, already resolved: one swapped for a link since, or moved under one,
    /// opens nothing, and no link below it is followed either. Only a regular file opens.
    public static func open(_ relative: String, in root: URL) throws -> FileHandle {
        try validate(relative)
        let refused = AppletError("\(relative.prefix(100)) is not a file inside the noodlet.")
        var folder = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw refused }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        // Resolving a path drops the /private that /var and /tmp lead to; the system's own links.
        let expected = root.standardizedFileURL.path
        guard fcntl(folder, F_GETPATH, &path) == 0, [expected, "/private" + expected].contains(String(cString: path)) else {
            close(folder)
            throw refused
        }
        let parts = relative.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            let next = openat(folder, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(folder)
            guard next >= 0 else { throw refused }
            folder = next
        }
        let file = openat(folder, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        close(folder)
        var info = stat()
        guard file >= 0, fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            if file >= 0 { close(file) }
            throw refused
        }
        return FileHandle(fileDescriptor: file, closeOnDealloc: true)
    }
}
