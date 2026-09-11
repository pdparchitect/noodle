import ComputerBridge
import Darwin
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
        var fd = Darwin.open(workspace.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ComputerBridgeError("Cannot open the bot workspace.") }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw ComputerBridgeError("The local parent folder must exist and cannot be a symlink.") }
            fd = next
        }
        return (fd, parts.last!)
    }

    public static func upload(workspace: URL, path: String, to staging: URL) throws -> Int64 {
        let (parent, name) = try parent(workspace: workspace, path: path)
        defer { Darwin.close(parent) }
        let source = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw ComputerBridgeError("Cannot read the local file; symlinks are not supported.") }
        defer { Darwin.close(source) }
        _ = try ComputerTransferFiles.size(source)
        let destination = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw ComputerBridgeError("Cannot stage the upload.") }
        defer { Darwin.close(destination) }
        return try ComputerTransferFiles.copy(source: source, destination: destination)
    }
}

/// Keep the selected parent open until publication. An existing file, symlink,
/// or directory is never replaced, even if it appears while downloading.
public final class ComputerWorkspaceDownload: @unchecked Sendable {
    private let parent: Int32
    private let name: String
    private let temporary = ".noodle-download-" + UUID().uuidString.lowercased()
    private var published = false

    public init(workspace: URL, path: String) throws {
        let (directory, filename) = try ComputerWorkspaceFiles.parent(workspace: workspace, path: path)
        var info = stat()
        guard fstatat(directory, filename, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            Darwin.close(directory)
            throw ComputerBridgeError("The local destination already exists or cannot be inspected. Choose a new file name.")
        }
        parent = directory; name = filename
    }

    public func copy(from staging: URL, expected: Int64) throws -> Int64 {
        let source = try ComputerTransferFiles.openSource(staging)
        defer { Darwin.close(source) }
        guard try ComputerTransferFiles.size(source) == expected else { throw ComputerBridgeError("Incomplete download.") }
        let destination = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw ComputerBridgeError("Cannot stage the download in its destination folder.") }
        defer { Darwin.close(destination) }
        return try ComputerTransferFiles.copy(source: source, destination: destination)
    }

    public func publish() throws {
        guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else {
            throw ComputerBridgeError("Cannot save the download; the destination may already exist.")
        }
        published = true
    }

    deinit {
        if !published { unlinkat(parent, temporary, 0) }
        Darwin.close(parent)
    }
}
