import ComputerBridge
import ComputerCore
import Foundation
import NIOCore

/// A computer reached over SSH: one signed-in connection that terminals and files share.
@MainActor public final class SSHComputer {
    let connection: SSHConnection
    var onDisconnect: ((String) -> Void)?
    private(set) var connected = true
    private var expected = false

    init(connection: SSHConnection) {
        self.connection = connection
        connection.closed.whenComplete { [weak self] _ in
            Task { @MainActor in self?.disconnected() }
        }
    }

    private func disconnected() {
        guard connected else { return }
        connected = false
        if !expected { onDisconnect?("The connection to the server closed. Start the computer to connect again.") }
    }

    func close() { expected = true; connection.close() }
}

/// The terminal shown in the window: a login shell on the server.
@MainActor public final class SSHTerminalConnection {
    let terminal: GuestTerminal
    private let connection: SSHConnection
    private var channel: Channel?
    private var input: Task<Void, Never>?
    /// The shell exited; opening Terminal again starts a new one.
    private(set) var ended = false

    init(connection: SSHConnection, terminal: GuestTerminal) { self.connection = connection; self.terminal = terminal }

    func start() async throws {
        let io = terminal.io
        let screen = terminal.view.getTerminal()
        let channel = try await SSHShell.open(on: connection, columns: screen.cols, rows: screen.rows, output: { data in
            try? io.write(data)
        }, exited: { [weak self] in
            try? io.write(Data("\r\n[Shell exited. Press Return to open a new shell.]\r\n".utf8))
            Task { @MainActor in self?.shellExited() }
        })
        ended = false
        self.channel = channel
        terminal.resize = { columns, rows in SSHShell.resize(channel, columns: columns, rows: rows) }
        input = Task { for await data in io.stream() { SSHShell.write(data, to: channel) } }
    }

    private func shellExited() {
        guard channel != nil else { return }
        ended = true
        input?.cancel()
        terminal.retryConnection = { [weak self] in
            guard let self else { return }
            self.terminal.retryConnection = nil
            self.terminal.reconnect()
            Task {
                do { try await self.start() }
                catch {
                    try? self.terminal.io.write(Data("\r\nCould not open a shell: \(error.localizedDescription)\r\n".utf8))
                    self.shellExited()
                }
            }
        }
    }

    func close() {
        input?.cancel()
        terminal.retryConnection = nil
        channel?.close(promise: nil)
        channel = nil
        terminal.io.finish()
    }
}

/// A client's shell on the server, with its output kept for reading back.
@MainActor final class SSHProviderTerminal {
    let computerID: UUID
    let owner: String
    let connection: SSHConnection
    var replay = TerminalReplay()
    var exited = false
    var touched = Date()
    var opened = Date()
    /// The person's own terminal, never closed for being idle.
    var person = false
    private var channel: Channel?

    private init(computerID: UUID, owner: String, connection: SSHConnection) {
        self.computerID = computerID; self.owner = owner; self.connection = connection
    }

    static func open(computerID: UUID, owner: String, connection: SSHConnection) async throws -> SSHProviderTerminal {
        let terminal = SSHProviderTerminal(computerID: computerID, owner: owner, connection: connection)
        terminal.channel = try await SSHShell.open(on: connection, columns: 120, rows: 30, output: { [weak terminal] data in
            Task { @MainActor in terminal?.replay.append(data) }
        }, exited: { [weak terminal] in
            Task { @MainActor in terminal?.exited = true }
        })
        return terminal
    }

    func write(_ data: Data) { if let channel { SSHShell.write(data, to: channel) } }
    func resize(columns: Int, rows: Int) { if let channel { SSHShell.resize(channel, columns: columns, rows: rows) } }
    func close() { exited = true; channel?.close(promise: nil); channel = nil }
}

/// The server's files over SFTP, for the same browser, preview, import, export and drag workflows the other computers use.
actor SSHFileService: ComputerFileService {
    static let listLimit = 5000
    private let connection: SSHConnection
    private var client: SFTPClient?

    init(connection: SSHConnection) { self.connection = connection }

    private func sftp() async throws -> SFTPClient {
        if let client, client.isOpen { return client }
        let opened = try await SFTPClient.open(on: connection)
        client = opened
        return opened
    }

    func close() { client?.close(); client = nil }

    func homeDirectory() async throws -> String {
        try GuestFile.normalize(try await sftp().realpath("."))
    }

    func list(_ path: String) async throws -> [GuestFile] {
        let entries = try await sftp().list(path, limit: Self.listLimit)
        let files = entries.compactMap { entry -> GuestFile? in
            // Names Files cannot show or address, such as ones that are not UTF-8, are left out.
            guard let name = String(data: entry.name, encoding: .utf8), (try? GuestFile.validateName(name)) != nil else { return nil }
            let attributes = entry.attributes
            return GuestFile(name: name, kind: attributes.kind, size: Int64(clamping: attributes.size ?? 0),
                             modified: Int64(attributes.modified ?? 0), version: attributes.version)
        }
        return files.sorted { a, b in a.directory != b.directory ? a.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    private func file(at path: String) async throws -> GuestFile {
        let attributes = try await sftp().lstat(path)
        let name = (path as NSString).lastPathComponent
        return GuestFile(name: name.isEmpty ? "/" : name, kind: attributes.kind, size: Int64(clamping: attributes.size ?? 0),
                         modified: Int64(attributes.modified ?? 0), version: attributes.version)
    }

    func read(_ file: GuestFile, path: String, to destination: URL, preview: Bool,
              progress: @escaping @Sendable (Int64) -> Void) async throws {
        let limit = preview ? PreviewPolicy.fileLimit : FileImportPlan.fileLimit
        guard file.regular, file.size >= 0, file.size <= limit else {
            throw ComputerError(preview ? "This file is too large to preview." : "Only regular files up to 8 GB can be exported.")
        }
        let sftp = try await sftp()
        let handle = try await sftp.openFile(path, .read)
        defer { Task { try? await sftp.closeHandle(handle) } }
        let current = try await sftp.fstat(handle)
        guard current.kind == "file", current.version == file.version else { throw ComputerError("The file changed; refresh and try again.") }
        let output = try FileOutput(limit: file.size, url: destination, progress: progress)
        do {
            try await withTaskCancellationHandler {
                try await sftp.download(handle, size: UInt64(file.size)) { try output.write($0) }
            } onCancel: { output.cancel() }
            _ = try output.finish(expected: file.size)
        } catch { output.cancel(); throw error }
    }

    func download(_ path: String, to destination: URL) async throws -> Int64 {
        let file = try await file(at: path)
        try await read(file, path: path, to: destination, preview: false)
        return file.size
    }

    /// Written beside the destination under a hidden name, then renamed into place, so a
    /// cancelled transfer never leaves a partial file and an existing item is never replaced.
    private func publish(to path: String, write: (SFTPClient, Data) async throws -> Void) async throws {
        let sftp = try await sftp()
        let folder = (path as NSString).deletingLastPathComponent
        let staging = try GuestFile.path(folder.isEmpty ? "/" : folder, ".noodle-\(UUID().uuidString.lowercased())")
        let handle = try await sftp.openFile(staging, [.write, .create, .exclusive], permissions: 0o644)
        do {
            try await write(sftp, handle)
            try await sftp.closeHandle(handle)
            try await sftp.rename(staging, to: path)
        } catch {
            try? await sftp.closeHandle(handle)
            try? await sftp.remove(staging)
            if let failure = error as? SFTPClient.Failure, failure.code == 4, (try? await sftp.lstat(path)) != nil {
                throw ComputerError("An item with that name already exists.")
            }
            throw error
        }
    }

    func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) async -> Void) async throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= FileImportPlan.fileLimit else {
            throw ComputerError("Choose a regular file up to 8 GB.")
        }
        let input = try FileInput(url: source, limit: Int64(size), progress: progress)
        try await publish(to: path) { sftp, handle in
            let written = try await withTaskCancellationHandler {
                try await sftp.upload(handle, from: input.stream())
            } onCancel: { input.cancel() }
            guard written == UInt64(size) else { throw ComputerError("The file changed or the transfer was incomplete.") }
        }
    }

    func createImportDirectory(_ path: String) async throws { try await sftp().mkdir(path) }

    func change(_ operation: String, path: String, extra: [String]) async throws {
        let sftp = try await sftp()
        switch operation {
        case "mkdir": try await sftp.mkdir(path)
        case "rename":
            guard let destination = extra.first else { throw ComputerError("Missing destination.") }
            try await sftp.rename(path, to: GuestFile.normalize(destination))
        case "remove":
            guard path != "/" else { throw ComputerError("Cannot remove the root folder.") }
            // Never recursive, as on the other computers; a link itself is removed.
            if try await sftp.lstat(path).kind == "directory" { try await sftp.rmdir(path) } else { try await sftp.remove(path) }
        case "copy":
            guard extra.count == 2 else { throw ComputerError("Missing file version or destination.") }
            let destination = try GuestFile.normalize(extra[1])
            let source = try await sftp.openFile(path, .read)
            defer { Task { try? await sftp.closeHandle(source) } }
            let attributes = try await sftp.fstat(source)
            guard attributes.kind == "file", attributes.version == extra[0] else { throw ComputerError("The file changed; refresh and try again.") }
            let size = attributes.size ?? 0
            try await publish(to: destination) { sftp, handle in
                var offset: UInt64 = 0
                while offset < size {
                    try Task.checkCancellation()
                    guard let data = try await sftp.read(source, offset: offset, length: SFTPClient.chunk), !data.isEmpty else { break }
                    try await sftp.write(handle, offset: offset, data: data)
                    offset += UInt64(data.count)
                }
                guard offset == size else { throw ComputerError("The file changed during the copy.") }
            }
        default: throw ComputerError("Unsupported file operation.")
        }
    }
}
