import Darwin
import Foundation
import MachO

/// An MCP server lives as long as its client's session, often across an update of the app that ships it. The
/// update replaces the server's executable, and from then on the app refuses the running process, whose code no
/// longer matches its file. So before each message the server compares the file with the one it started from;
/// when it changed, the server answers the calls it is running, then runs the new executable in its own place:
/// the same process on the same standard input and output, told the version the client initialised it with and
/// handed the messages read but not yet answered. The client sees no break.
struct MCPRelaunch: Sendable {
    /// Which file a path names, and the version of it.
    struct Identity: Equatable, Sendable {
        var device: UInt64, inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int
    }

    /// What the new executable is told, in `environmentKey`.
    struct Resume: Codable, Equatable, Sendable {
        /// The version the client initialised the server with; nil before it has.
        var protocolVersion: String?
        /// A descriptor holding the messages read but not yet answered.
        var pending: Int32?
    }

    static let environmentKey = "NOODLE_MCP_RESUME"

    /// The executable, resolved when the process started, and the file it was then.
    let path: String
    let launched: Identity
    let identity: @Sendable (String) -> Identity?
    /// Takes over the process with the pending messages and the client's version; returns only to say why it
    /// could not. Tests replace it, as nothing there may exec.
    let replace: (@Sendable (_ pending: Data, _ protocolVersion: String?) -> String)?

    init(path: String, launched: Identity, identity: @escaping @Sendable (String) -> Identity? = { MCPRelaunch.identity(of: $0) },
         replace: (@Sendable (_ pending: Data, _ protocolVersion: String?) -> String)? = nil) {
        self.path = path; self.launched = launched; self.identity = identity; self.replace = replace
    }

    /// Watches the file at `path` as it is now; nil when there is none.
    init?(path: String) {
        guard let identity = Self.identity(of: path) else { return nil }
        self.init(path: path, launched: identity)
    }

    /// The running process's own executable.
    static func current() -> MCPRelaunch? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0, let resolved = realpath(buffer, nil) else { return nil }
        defer { free(resolved) }
        return MCPRelaunch(path: String(cString: resolved))
    }

    static func identity(of path: String) -> Identity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Identity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: info.st_ino, size: info.st_size,
                        seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }

    /// A new file is in the executable's place. One missing halfway through an update is not new yet.
    var changed: Bool { identity(path).map { $0 != launched } ?? false }

    /// Runs the new executable in this process's place; returns only to say why it could not.
    func takeOver(pending: Data, protocolVersion: String?) -> String {
        if let replace { return replace(pending, protocolVersion) }
        let descriptor: Int32
        do { descriptor = try Self.stash(pending) } catch { return error.localizedDescription }
        defer { close(descriptor) }
        let environment = Self.environment(ProcessInfo.processInfo.environment,
                                           resume: Resume(protocolVersion: protocolVersion, pending: descriptor))
        let arguments = CommandLine.arguments.map { strdup($0) } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (arguments + variables).forEach { free($0) } }
        execve(path, arguments, variables)
        return String(cString: strerror(errno))
    }

    static func environment(_ base: [String: String], resume: Resume) -> [String: String] {
        var environment = base
        environment[environmentKey] = (try? JSONEncoder().encode(resume)).map { String(decoding: $0, as: UTF8.self) }
        return environment
    }

    static func resume(from environment: [String: String]) -> Resume? {
        environment[environmentKey].flatMap { try? JSONDecoder().decode(Resume.self, from: Data($0.utf8)) }
    }

    /// Keeps `data` in a file with no name, open on a descriptor the new executable inherits, so nothing is left
    /// on disk whatever happens.
    static func stash(_ data: Data) throws -> Int32 {
        var template = Array((NSTemporaryDirectory() + "noodle-mcp-XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw ExternalToolsError("Cannot keep the messages for the updated tool.") }
        unlink(template)
        let written = data.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written, lseek(descriptor, 0, SEEK_SET) == 0 else {
            close(descriptor)
            throw ExternalToolsError("Cannot keep the messages for the updated tool.")
        }
        return descriptor
    }

    /// Reads what `stash` kept, and closes it.
    static func unstash(_ descriptor: Int32) -> Data {
        defer { close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return data }
            data.append(contentsOf: buffer[..<count])
        }
    }
}
