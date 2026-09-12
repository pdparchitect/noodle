import ComputerCore
import Containerization
import Foundation
import Darwin

struct GuestFile: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let kind: String
    let size: Int64
    let modified: Int64
    let version: String
    var id: String { name }
    var displayName: String { name.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ") }
    var directory: Bool { kind == "directory" }
    var regular: Bool { kind == "file" }
    var symbol: String { directory ? "folder.fill" : kind == "symlink" ? "link" : "doc" }
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.utf8.contains(0), name.utf8.count <= 255 else { throw ComputerError("Choose a valid file name without slashes.") }
    }
    static func path(_ folder: String, _ name: String) throws -> String {
        try validateName(name)
        return folder == "/" ? "/" + name : folder + "/" + name
    }
    static func normalize(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else { throw ComputerError("Enter an absolute guest path.") }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// Host-side caps are authoritative, even if the guest lies about metadata.
final class FileOutput: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int64
    private var count: Int64 = 0
    private var buffer = Data()
    private var handle: FileHandle?
    private var failure: Error?
    init(limit: Int64, url: URL? = nil) throws {
        self.limit = limit
        if let url {
            let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                throw ComputerError("Cannot create the transfer file.")
            }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }
    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard Int64(data.count) <= limit - count else {
            let error = ComputerError("Transfer exceeded its size limit."); failure = error; throw error
        }
        count += Int64(data.count)
        do { if let handle { try handle.write(contentsOf: data) } else { buffer.append(data) } }
        catch { failure = error; throw error }
    }
    func close() throws {} // Ownership stays with the operation until all I/O finishes.
    func cancel() { lock.lock(); defer { lock.unlock() }; failure = CancellationError() }
    func finish(expected: Int64? = nil) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        defer { try? handle?.close(); handle = nil }
        if let failure { throw failure }
        if let expected, expected != count { throw ComputerError("The file changed or the transfer was incomplete.") }
        return buffer
    }
    deinit { try? handle?.close() }
}

/// Pull-based input avoids buffering a whole exported/imported file in memory.
final class FileInput: ReaderStream, @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int64
    private let progress: @Sendable (Int64) async -> Void
    private let lock = NSLock()
    private var cancelled = false
    init(url: URL, limit: Int64, progress: @escaping @Sendable (Int64) async -> Void = { _ in }) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ComputerError("Cannot read the selected file.") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == limit else {
            Darwin.close(fd); throw ComputerError("The selected file changed or is not a regular file.")
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); self.limit = limit; self.progress = progress
    }
    func cancel() { lock.withLock { cancelled = true } }
    func stream() -> AsyncStream<Data> {
        let handle = handle
        let limit = limit
        var remaining = limit
        var lastUpdate = ContinuousClock.now
        return AsyncStream(unfolding: {
            guard !Task.isCancelled, !self.lock.withLock({ self.cancelled }), remaining > 0 else { return nil }
            guard let data = try? handle.read(upToCount: Int(min(remaining, 65_536))), !data.isEmpty else { return nil }
            remaining -= Int64(data.count)
            let now = ContinuousClock.now
            if remaining == 0 || now - lastUpdate >= .milliseconds(100) {
                lastUpdate = now
                await self.progress(limit - remaining)
            }
            guard !Task.isCancelled, !self.lock.withLock({ self.cancelled }) else { return nil }
            return data
        })
    }
    deinit { try? handle.close() }
}

actor GuestFiles: FileImportDestination {
    let runtime: ContainerComputer
    private var installation: Task<String, Error>?
    init(runtime: ContainerComputer) { self.runtime = runtime }

    private func helper() async throws -> String {
        if let installation { return try await installation.value }
        let task = Task { () throws -> String in
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("Runtime/noodle-files"),
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                throw ComputerError("The file helper is missing. Rebuild Noodle Computer.")
            }
            let path = "/tmp/.noodle-files-runtime"
            let staging = path + "." + UUID().uuidString.lowercased()
            let input = try FileInput(url: url, limit: Int64(size))
            _ = try await run(arguments: ["/bin/sh", "-c", "umask 077; set -C; trap 'rm -f -- \"$2\"' EXIT; cat > \"$2\" && chmod 700 \"$2\" && mv -f -- \"$2\" \"$1\"", "noodle-files", path, staging], input: input, limit: 4096, timeout: 15)
            return path
        }
        installation = task
        do { return try await task.value } catch { installation = nil; throw error }
    }

    private func run(arguments: [String], input: FileInput? = nil, limit: Int64,
                     destination: URL? = nil, expected: Int64? = nil, timeout: Int64 = 15) async throws -> Data {
        try Task.checkCancellation()
        let output = try FileOutput(limit: limit, url: destination)
        let errors = try FileOutput(limit: 8192)
        let process = try await runtime.makeFileProcess(arguments: arguments, input: input, output: output, errors: errors)
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            input?.cancel()
            output.cancel()
            try? await process.kill(.term)
            try? await Task.sleep(for: .milliseconds(200))
            try? await process.kill(.kill)
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await process.start()
                let result = try await process.wait(timeoutInSeconds: timeout)
                try await process.delete()
                try Task.checkCancellation()
                let message = try errors.finish()
                guard result.exitCode == 0 else {
                    throw ComputerError(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(500).description)
                }
                return try output.finish(expected: expected)
            } catch {
                input?.cancel()
                try? await process.kill(.term)
                try? await process.delete()
                throw error
            }
        } onCancel: {
            input?.cancel()
            output.cancel()
            Task { try? await process.kill(.term) }
        }
    }

    func list(_ path: String) async throws -> [GuestFile] {
        let helper = try await helper()
        let data = try await run(arguments: [helper, "list", path], limit: 4 * 1024 * 1024)
        let files = try JSONDecoder().decode([GuestFile].self, from: data)
        guard files.count <= 5000, Set(files.map(\.name)).count == files.count else { throw ComputerError("Invalid folder listing.") }
        for file in files {
            try GuestFile.validateName(file.name)
            guard file.size >= 0, file.version.utf8.count <= 200, ["file", "directory", "symlink", "other"].contains(file.kind) else { throw ComputerError("Invalid file metadata.") }
        }
        return files.sorted { a, b in a.directory != b.directory ? a.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    func read(_ file: GuestFile, path: String, to destination: URL, preview: Bool) async throws {
        let limit: Int64 = preview ? PreviewPolicy.fileLimit : 8 * 1024 * 1024 * 1024
        guard file.regular, file.size <= limit else { throw ComputerError(preview ? "This file is too large to preview." : "Only regular files up to 8 GB can be exported.") }
        let helper = try await helper()
        _ = try await run(arguments: [helper, "read", path, file.version, String(limit)], limit: min(limit, file.size), destination: destination, expected: file.size, timeout: preview ? 2 : 300)
    }

    func download(_ path: String, to destination: URL) async throws -> Int64 {
        let helper = try await helper()
        let data = try await run(arguments: [helper, "stat", path], limit: 8192)
        let file = try JSONDecoder().decode(GuestFile.self, from: data)
        guard file.size >= 0, file.version.utf8.count <= 200 else { throw ComputerError("Invalid file metadata.") }
        try await read(file, path: path, to: destination, preview: false)
        return file.size
    }

    func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) async -> Void = { _ in }) async throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 8 * 1024 * 1024 * 1024 else {
            throw ComputerError("Choose a regular file up to 8 GB.")
        }
        let helper = try await helper()
        _ = try await run(arguments: [helper, "write", path, String(size)], input: FileInput(url: source, limit: Int64(size), progress: progress), limit: 4096, timeout: 300)
    }

    func importItems(_ urls: [URL], to folder: String, progress: @escaping @Sendable (FileImportProgress) async -> Void) async throws {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        let plan = try FileImportPlan.prepare(urls, folder: folder)
        try await plan.send(to: self, progress: progress)
    }

    func createImportDirectory(_ path: String) async throws {
        try await change("mkdir", path: path)
    }

    func change(_ operation: String, path: String, extra: [String] = []) async throws {
        guard ["mkdir", "rename", "remove", "copy"].contains(operation) else { throw ComputerError("Unsupported file operation.") }
        let helper = try await helper()
        _ = try await run(arguments: [helper, operation, path] + extra, limit: 4096, timeout: 30)
    }
}
