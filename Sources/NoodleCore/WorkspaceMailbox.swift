import Darwin
import Foundation
import ComputerBridge

/// A broker holds the directory descriptor across I/O. A bot cannot redirect a
/// privileged read, write, rename, or chmod by replacing a mailbox with a link.
public final class WorkspaceMailbox: @unchecked Sendable {
    private let descriptor: Int32
    public let url: URL

    public init(workspace: URL, path: String, create: Bool = false) throws {
        let parts = path.split(separator: "/").map(String.init)
        guard !path.hasPrefix("/"),
              parts.allSatisfy({ Self.validName($0) }) else { throw Self.invalid() }
        var current = open(workspace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw Self.invalid() }
        for part in parts {
            if create, mkdirat(current, part, 0o700) != 0, errno != EEXIST {
                close(current); throw Self.invalid()
            }
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw Self.invalid() }
            current = next
        }
        descriptor = current
        url = workspace.appendingPathComponent(path)
    }

    deinit { close(descriptor) }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") &&
            !value.utf8.contains(0) && value.utf8.count <= 255
    }
    private static func invalid() -> HarnessSetupError {
        HarnessSetupError("The bot mailbox is unavailable or redirected. Restart the bot after restoring its workspace.")
    }

    public func names(limit: Int = 512) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0, let directory = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw Self.invalid()
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var values: [String] = []
        while values.count < limit, let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if Self.validName(name) { values.append(name) }
        }
        return values
    }

    public func read(_ name: String, limit: Int) throws -> Data {
        guard Self.validName(name) else { throw Self.invalid() }
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Self.invalid() }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else { throw Self.invalid() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Self.invalid() }
        return data
    }

    public func write<T: Encodable>(_ value: T, named name: String) throws {
        try writeData(JSONEncoder().encode(value), named: name)
    }

    public func writeData(_ data: Data, named name: String) throws {
        guard Self.validName(name) else { throw Self.invalid() }
        let temporary = "." + UUID().uuidString.lowercased()
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Self.invalid() }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(descriptor, temporary, 0) }
        try handle.write(contentsOf: data)
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw Self.invalid() }
    }

    public func claim(_ name: String, as claimed: String) throws {
        guard Self.validName(name), Self.validName(claimed),
              renameatx_np(descriptor, name, descriptor, claimed, UInt32(RENAME_EXCL)) == 0 else { throw Self.invalid() }
    }

    public func copy(from source: URL, named name: String) throws {
        guard Self.validName(name) else { throw Self.invalid() }
        let input = try ComputerTransferFiles.openSource(source)
        defer { close(input) }
        let temporary = "." + UUID().uuidString.lowercased()
        let output = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Self.invalid() }
        defer { close(output); unlinkat(descriptor, temporary, 0) }
        _ = try ComputerTransferFiles.copy(source: input, destination: output)
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw Self.invalid() }
    }

    public func remove(_ name: String) {
        guard Self.validName(name) else { return }
        unlinkat(descriptor, name, 0)
    }

    public func withLock(_ name: String, operation: () throws -> Void) rethrows {
        guard Self.validName(name) else { return }
        let file = openat(descriptor, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard file >= 0 else { return }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              flock(file, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(file, LOCK_UN) }
        try operation()
    }

    public func contains(_ name: String) -> Bool {
        guard Self.validName(name) else { return false }
        var info = stat()
        return fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    public func linkDestination(_ name: String) -> String? {
        guard Self.validName(name) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlinkat(descriptor, name, &buffer, buffer.count - 1)
        guard length >= 0, length < buffer.count - 1 else { return nil }
        return String(cString: buffer)
    }

    public func symlink(_ name: String, destination: String) throws {
        guard Self.validName(name), !destination.utf8.contains(0) else { throw Self.invalid() }
        let temporary = "." + UUID().uuidString.lowercased()
        guard symlinkat(destination, descriptor, temporary) == 0 else { throw Self.invalid() }
        defer { unlinkat(descriptor, temporary, 0) }
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw Self.invalid() }
    }

    public func removeEmptyDirectory(_ name: String) {
        guard Self.validName(name) else { return }
        unlinkat(descriptor, name, AT_REMOVEDIR)
    }

    /// Remove only generated files. Extra user files keep the directory alive.
    public static func synchronizeSkill(workspace: URL, name: String, enabled: Bool,
                                        instructions: String, command: String, executable: URL?) throws {
        if !enabled, (try? WorkspaceMailbox(workspace: workspace, path: ".agents/skills")) == nil { return }
        let skills = try WorkspaceMailbox(workspace: workspace, path: ".agents/skills", create: enabled)
        var folder: WorkspaceMailbox?
        if skills.contains(name) {
            folder = try WorkspaceMailbox(workspace: workspace, path: ".agents/skills/" + name)
            guard folder!.contains(".noodle-managed") else {
                if enabled { throw HarnessSetupError("The \(name) skill name is occupied by a user skill.") }
                return
            }
        }
        guard enabled else {
            for file in [".noodle-managed", "SKILL.md", command] { folder?.remove(file) }
            skills.removeEmptyDirectory(name)
            if let native = try? WorkspaceMailbox(workspace: workspace, path: ".claude/skills"),
               native.linkDestination(name) == "../../.agents/skills/" + name { native.remove(name) }
            return
        }
        let target = try folder ?? WorkspaceMailbox(workspace: workspace, path: ".agents/skills/" + name, create: true)
        try target.writeData(Data(), named: ".noodle-managed")
        try target.writeData(Data(instructions.utf8), named: "SKILL.md")
        if let executable { try target.symlink(command, destination: executable.path) }
    }
}
