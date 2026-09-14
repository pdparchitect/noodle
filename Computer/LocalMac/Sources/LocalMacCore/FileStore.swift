import Foundation
import Darwin

/// Account-local file operations. Every parent is opened relative to the home
/// descriptor without following links; even a renamed parent cannot redirect
/// traversal into another account. The desktop verifies its session separately.
public final class LocalMacFileStore {
    public static let fileLimit: Int64 = 8 * 1024 * 1024 * 1024
    /// The verified account home is mounted at the root of this file namespace.
    public var homeDirectory: String { "/" }
    private let home: String
    private let root: Int32
    private var uploads: [UUID: Upload] = [:]
    private final class Upload {
        let parent: Int32
        let temporary: String
        let destination: String
        let file: FileHandle
        let size: Int64
        var offset: Int64 = 0
        init(parent: Int32, temporary: String, destination: String, fd: Int32, size: Int64) {
            self.parent = parent; self.temporary = temporary; self.destination = destination
            file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); self.size = size
        }
        deinit { try? file.close(); unlinkat(parent, temporary, 0); Darwin.close(parent) }
    }
    public init(home: String) throws {
        self.home = home
        root = Darwin.open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw LocalMacError("Cannot open the account's home.") }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_uid == getuid() else {
            Darwin.close(root); throw LocalMacError("The home directory belongs to a different account.")
        }
    }
    deinit { Darwin.close(root) }
    public func close() { uploads.removeAll() }
    private func parts(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else { throw LocalMacError("Use an absolute account path.") }
        let relative = path == home ? "/" : path.hasPrefix(home + "/") ? String(path.dropFirst(home.count)) : path
        let components = relative.split(separator: "/").map(String.init)
        guard !components.contains(".."), components.allSatisfy({ $0.utf8.count <= 255 }),
              !relative.hasPrefix("/Users/") else { throw LocalMacError("File access is confined to this account's home.") }
        return components.filter { $0 != "." }
    }
    private func directory(_ parts: ArraySlice<String>) throws -> Int32 {
        // A fresh descriptor avoids sharing a directory-read offset with root.
        var fd = openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.accessError(errno, path: "/") }
        var traversed: [String] = []
        for part in parts {
            traversed.append(part)
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            // Darwin may report ENOTDIR for O_DIRECTORY | O_NOFOLLOW on a
            // symlink. Inspect metadata without traversing it before closing fd.
            var info = stat()
            let isLink = next < 0 && fstatat(fd, part, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFLNK
            Darwin.close(fd)
            guard next >= 0 else { throw Self.accessError(failure, path: "/" + traversed.joined(separator: "/"), isLink: isLink) }
            fd = next
        }
        return fd
    }
    static func accessError(_ code: Int32, path: String, isLink: Bool = false) -> LocalMacError {
        if isLink || code == ELOOP {
            return LocalMacError("Cannot open “\(path)”: symbolic-link folders are not traversed.")
        }
        switch code {
        case EPERM:
            let top = path.split(separator: "/").first.map(String.init)
            if let top, ["Desktop", "Documents", "Downloads"].contains(top) {
                return LocalMacError("macOS denied access to “\(path)”. In this Local Mac account’s desktop, allow \(top) access for Noodle Local Mac Desktop in System Settings → Privacy & Security → Files & Folders, then retry.")
            }
            return LocalMacError("macOS denied access to “\(path)” (Operation not permitted). This item may be protected by the account’s privacy settings.")
        case EACCES:
            return LocalMacError("This Local Mac account does not have permission to access “\(path)”. Check the item’s Sharing & Permissions in the account’s Finder.")
        case ENOENT: return LocalMacError("“\(path)” no longer exists. Refresh the folder and try again.")
        case ENOTDIR: return LocalMacError("“\(path)” is not a folder.")
        default: return LocalMacError("Cannot access “\(path)”: \(String(cString: strerror(code))) (\(code)).")
        }
    }
    private func parent(_ path: String, changing: Bool = false) throws -> (Int32, String) {
        let p = try parts(path)
        if changing, p.isEmpty || p == ["workspace"] { throw LocalMacError("Cannot change the account's root or workspace folder.") }
        return (try directory(p.dropLast()), p.last ?? ".")
    }
    private func metadata(_ name: String, _ info: stat) -> LocalMacFile {
        let kind: String
        switch info.st_mode & S_IFMT { case S_IFREG: kind = "file"; case S_IFDIR: kind = "directory"; case S_IFLNK: kind = "symlink"; default: kind = "other" }
        let version = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        return LocalMacFile(name: name, kind: kind, size: info.st_size, modified: Int64(info.st_mtimespec.tv_sec), version: version)
    }
    public func statFile(_ path: String) throws -> LocalMacFile {
        let (fd, name) = try parent(path); defer { Darwin.close(fd) }
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw LocalMacError("Cannot inspect this account file.") }
        return metadata(name, info)
    }
    public func list(_ path: String) throws -> [LocalMacFile] {
        let fd = try directory(ArraySlice(parts(path)))
        guard let dir = fdopendir(fd) else { let failure = errno; Darwin.close(fd); throw Self.accessError(failure, path: path) }
        defer { closedir(dir) }
        var result: [LocalMacFile] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                guard errno == 0 else { throw Self.accessError(errno, path: path) }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < 5000 else { throw LocalMacError("Folder exceeds the 5,000-item browsing limit.") }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw LocalMacError("Folder changed while it was being read. Refresh to retry.") }
            result.append(metadata(name, info))
        }
        return result.sorted { a, b in a.directory != b.directory ? a.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    private func regular(_ path: String, version: String) throws -> FileHandle {
        let (folderFD, name) = try parent(path); defer { Darwin.close(folderFD) }
        let fd = openat(folderFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.accessError(errno, path: path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              (0...Self.fileLimit).contains(info.st_size), metadata(name, info).version == version else {
            throw LocalMacError("The file changed or is not a regular file. Refresh to retry.")
        }
        return handle
    }
    public func read(_ path: String, version: String, offset: Int64) throws -> Data {
        guard offset >= 0, offset <= Self.fileLimit else { throw LocalMacError("Invalid file offset.") }
        let file = try regular(path, version: version); defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        let data = try file.read(upToCount: 262_144) ?? Data()
        var after = stat()
        guard fstat(file.fileDescriptor, &after) == 0, metadata("", after).version == version else { throw LocalMacError("File changed during transfer.") }
        return data
    }
    public func beginUpload(_ path: String, size: Int64) throws -> UUID {
        guard uploads.count < 4, (0...Self.fileLimit).contains(size) else { throw LocalMacError("Invalid or busy file transfer.") }
        let (parent, name) = try parent(path, changing: true)
        let id = UUID(), temporary = ".noodle-upload-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { Darwin.close(parent); throw LocalMacError("Cannot prepare the uploaded file.") }
        uploads[id] = Upload(parent: parent, temporary: temporary, destination: name, fd: fd, size: size)
        return id
    }
    public func write(_ id: UUID, offset: Int64, data: Data) throws -> Int64 {
        guard let upload = uploads[id], upload.offset == offset, data.count <= 262_144,
              Int64(data.count) <= upload.size - offset else { throw LocalMacError("Invalid upload chunk.") }
        try upload.file.write(contentsOf: data); upload.offset += Int64(data.count)
        return upload.offset
    }
    public func commit(_ id: UUID) throws {
        guard let upload = uploads[id], upload.offset == upload.size else { throw LocalMacError("The upload is incomplete.") }
        defer { uploads.removeValue(forKey: id) }
        try upload.file.synchronize()
        guard renameatx_np(upload.parent, upload.temporary, upload.parent, upload.destination, UInt32(RENAME_EXCL)) == 0 else {
            throw LocalMacError("Cannot publish this file. Existing files are preserved; choose a new name.")
        }
    }
    public func cancel(_ id: UUID) { uploads.removeValue(forKey: id) }
    public func mkdir(_ path: String) throws {
        let (fd, name) = try parent(path, changing: true); defer { Darwin.close(fd) }
        guard mkdirat(fd, name, 0o700) == 0 else { throw LocalMacError("Cannot create this folder. An existing item may have the same name.") }
    }
    public func remove(_ path: String) throws {
        let (fd, name) = try parent(path, changing: true); defer { Darwin.close(fd) }
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              unlinkat(fd, name, info.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
            throw LocalMacError("Cannot delete this item. Only files and empty folders can be deleted.")
        }
    }
    public func rename(_ path: String, to destination: String) throws {
        let (oldFD, old) = try parent(path, changing: true); defer { Darwin.close(oldFD) }
        let (newFD, new) = try parent(destination, changing: true); defer { Darwin.close(newFD) }
        guard renameatx_np(oldFD, old, newFD, new, UInt32(RENAME_EXCL)) == 0 else { throw LocalMacError("Cannot move this item. Existing files are preserved.") }
    }
    public func copy(_ path: String, version: String, to destination: String) throws {
        let source = try regular(path, version: version); defer { try? source.close() }
        var info = stat(); guard fstat(source.fileDescriptor, &info) == 0 else { throw LocalMacError("Cannot inspect the source file.") }
        let id = try beginUpload(destination, size: info.st_size); defer { cancel(id) }
        var offset: Int64 = 0
        while let data = try source.read(upToCount: 262_144), !data.isEmpty { offset = try write(id, offset: offset, data: data) }
        guard fstat(source.fileDescriptor, &info) == 0, metadata("", info).version == version else { throw LocalMacError("File changed during copy.") }
        try commit(id)
    }
}
