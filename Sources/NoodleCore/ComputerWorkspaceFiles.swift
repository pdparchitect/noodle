import ComputerBridge
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The broker rechecks local access independently of the CLI. Walking directory
/// descriptors prevents a symlink swap from redirecting I/O outside the workspace.
public enum ComputerWorkspaceFiles {
    public static func relativePath(_ path: String, currentDirectory: URL, workspace: URL) throws -> String {
        guard !path.isEmpty, !path.utf8.contains(0), path.utf8.count <= 4096 else {
            throw ComputerBridgeError("Specify a workspace file path.")
        }
        // Preserve '..' until descriptor validation; lexical normalization can
        // silently change the meaning of a path that traverses a symlink.
        let root = workspace.resolvingSymlinksInPath().path
        let absolute = path.hasPrefix("/") ? path : currentDirectory.resolvingSymlinksInPath().path + "/" + path
        guard absolute.hasPrefix(root + "/") else { throw ComputerBridgeError("Local files must be inside this bot's workspace.") }
        let relative = String(absolute.dropFirst(root.count + 1))
        _ = try components(relative)
        return relative
    }

    private static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096,
              !parts.isEmpty, parts.allSatisfy({ $0 != ".." && $0.utf8.count <= 255 }) else {
            throw ComputerBridgeError("Use a workspace-relative file path without '..' or symlinks.")
        }
        return parts
    }

    static func parent(workspace: URL, path: String) throws -> (Int32, String) {
        let parts = try components(path)
        var fd = systemOpen(workspace.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ComputerBridgeError("Cannot open the bot workspace.") }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            systemClose(fd)
            guard next >= 0 else { throw ComputerBridgeError("The local parent folder must exist and cannot be a symlink.") }
            fd = next
        }
        return (fd, parts.last!)
    }

    public static func upload(workspace: URL, path: String, to staging: URL) throws -> Int64 {
        let (parent, name) = try parent(workspace: workspace, path: path)
        defer { systemClose(parent) }
        let source = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw ComputerBridgeError("Cannot read the local file; symlinks are not supported.") }
        defer { systemClose(source) }
        _ = try ComputerTransferFiles.size(source)
        let destination = systemOpen(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw ComputerBridgeError("Cannot stage the upload.") }
        defer { systemClose(destination) }
        return try ComputerTransferFiles.copy(source: source, destination: destination)
    }

    /// Bounded script/JSON input, including files directly in the workspace.
    /// Use the same descriptor walk as transfers; never follow parent or leaf links.
    public static func read(workspace: URL, path: String, limit: Int) throws -> Data {
        guard limit >= 0, limit < Int.max else { throw ComputerBridgeError("Invalid workspace file size limit.") }
        let (parent, name) = try parent(workspace: workspace, path: path)
        defer { systemClose(parent) }
        let source = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw ComputerBridgeError("Cannot read the local file; symlinks are not supported.") }
        defer { systemClose(source) }
        var info = stat()
        guard fstat(source, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else {
            throw ComputerBridgeError("Expected a regular workspace file within the size limit.")
        }
        let data = try FileHandle(fileDescriptor: source, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ComputerBridgeError("Workspace file exceeds the size limit.") }
        return data
    }
}
