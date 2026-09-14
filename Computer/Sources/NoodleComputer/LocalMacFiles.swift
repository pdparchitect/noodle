import AppKit
import ComputerCore
import Foundation
import LocalMacCore

@MainActor final class LocalMacTerminalConnection {
    let runtime: LocalMacComputer
    let terminal: GuestTerminal
    var id: UUID?
    var tasks: [Task<Void, Never>] = []
    init(runtime: LocalMacComputer, terminal: GuestTerminal) { self.runtime = runtime; self.terminal = terminal }
    func start() async throws {
        guard let id = try await runtime.call(.init(.terminalOpen)).terminalID else { throw ComputerError("The account did not open a terminal.") }
        self.id = id
        terminal.resize = { [weak self] width, height in
            guard let self else { return }
            var request = LocalMacRequest(.terminalResize); request.terminalID = id; request.width = width; request.height = height
            Task { _ = try? await self.runtime.call(request) }
        }
        let io = terminal.io
        tasks.append(Task { [weak self] in
            var offset: Int64 = 0
            while !Task.isCancelled {
                guard let self else { return }
                var request = LocalMacRequest(.terminalRead); request.terminalID = id; request.offset = offset
                do {
                    let reply = try await runtime.call(request)
                    if let data = reply.data, !data.isEmpty { try io.write(data) }
                    offset = reply.offset ?? offset
                    if reply.exited == true { try io.write(Data("\r\n[Shell exited]\r\n".utf8)); return }
                } catch { try? io.write(Data(("\r\n" + error.localizedDescription + "\r\n").utf8)); return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        })
        tasks.append(Task { [weak self] in
            for await data in io.stream() {
                guard !Task.isCancelled, let self else { return }
                var request = LocalMacRequest(.terminalWrite); request.terminalID = id; request.data = data
                do { _ = try await runtime.call(request) } catch { return }
            }
        })
    }
    func close() {
        for task in tasks { task.cancel() }; tasks.removeAll()
        terminal.io.finish()
        if let id {
            self.id = nil
            var request = LocalMacRequest(.terminalClose); request.terminalID = id
            Task { [runtime] in _ = try? await runtime.call(request) }
        }
    }
    deinit { for task in tasks { task.cancel() } }
}

/// Supplies account files to the same browser, preview, import/export and drag
/// workflows used by containers. The privileged service never handles file I/O.
@MainActor final class LocalMacFileService: ComputerFileService {
    let runtime: LocalMacComputer
    init(runtime: LocalMacComputer) { self.runtime = runtime }
    func homeDirectory() async throws -> String {
        guard let path = try await runtime.call(.init(.fileHome)).homeDirectory else {
            throw ComputerError("The account returned no home directory.")
        }
        return try GuestFile.normalize(path)
    }
    private func metadata(_ file: LocalMacFile) throws -> GuestFile {
        try GuestFile.validateName(file.name)
        guard file.size >= 0, file.version.utf8.count <= 200,
              ["file", "directory", "symlink", "other"].contains(file.kind) else { throw ComputerError("Invalid file metadata.") }
        return GuestFile(name: file.name, kind: file.kind, size: file.size, modified: file.modified, version: file.version)
    }
    func list(_ path: String) async throws -> [GuestFile] {
        var request = LocalMacRequest(.fileList); request.path = try GuestFile.normalize(path)
        let files = try await runtime.call(request).files ?? []
        guard files.count <= 5000, Set(files.map(\.name)).count == files.count else { throw ComputerError("Invalid folder listing.") }
        return try files.map(metadata)
    }
    func stat(_ path: String) async throws -> GuestFile {
        var request = LocalMacRequest(.fileStat); request.path = try GuestFile.normalize(path)
        guard let file = try await runtime.call(request).files?.first else { throw ComputerError("The account returned no file metadata.") }
        return try metadata(file)
    }
    func read(_ file: GuestFile, path: String, to destination: URL, preview: Bool,
              progress: @escaping @Sendable (Int64) -> Void) async throws {
        let limit = preview ? PreviewPolicy.fileLimit : FileImportPlan.fileLimit
        guard file.regular, file.size >= 0, file.size <= limit else { throw ComputerError("This file cannot be previewed or transferred.") }
        let output = try FileOutput(limit: file.size, url: destination, progress: progress)
        var offset: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                var request = LocalMacRequest(.fileRead)
                request.path = path; request.version = file.version; request.offset = offset
                let reply = try await runtime.call(request)
                guard let data = reply.data, reply.offset == offset + Int64(data.count) else { throw ComputerError("Invalid file chunk.") }
                try output.write(data); offset += Int64(data.count)
                if data.isEmpty { break }
            }
            _ = try output.finish(expected: file.size)
        } catch { output.cancel(); throw error }
    }
    func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) async -> Void) async throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= FileImportPlan.fileLimit else { throw ComputerError("Choose a regular file up to 8 GB.") }
        let input = try FileInput(url: source, limit: Int64(size))
        var begin = LocalMacRequest(.fileUploadOpen); begin.path = path; begin.size = Int64(size)
        try Task.checkCancellation()
        guard let id = try await runtime.call(begin).transferID else { throw ComputerError("The account did not open an upload.") }
        do {
            var offset: Int64 = 0
            for await data in input.stream() {
                try Task.checkCancellation()
                var request = LocalMacRequest(.fileWrite)
                request.transferID = id; request.offset = offset; request.data = data
                let reply = try await runtime.call(request)
                guard reply.offset == offset + Int64(data.count) else { throw ComputerError("The account did not confirm the uploaded bytes.") }
                offset += Int64(data.count); await progress(offset)
            }
            try Task.checkCancellation()
            guard offset == Int64(size) else { throw ComputerError("The selected file changed during import.") }
            var commit = LocalMacRequest(.fileUploadCommit); commit.transferID = id
            _ = try await runtime.call(commit)
        } catch {
            input.cancel()
            var cancel = LocalMacRequest(.fileUploadCancel); cancel.transferID = id
            _ = try? await runtime.call(cancel)
            throw error
        }
    }
    func createImportDirectory(_ path: String) async throws { try await change("mkdir", path: path, extra: []) }
    func change(_ operation: String, path: String, extra: [String]) async throws {
        let action: LocalMacOperation
        switch operation { case "mkdir": action = .fileMkdir; case "rename": action = .fileRename
        case "remove": action = .fileRemove; case "copy": action = .fileCopy
        default: throw ComputerError("Unsupported file operation.") }
        var request = LocalMacRequest(action); request.path = path
        if operation == "rename" {
            guard extra.count == 1 else { throw ComputerError("Missing destination.") }; request.destination = extra[0]
        } else if operation == "copy" {
            guard extra.count == 2 else { throw ComputerError("Missing file version or destination.") }
            request.version = extra[0]; request.destination = extra[1]
        }
        try Task.checkCancellation()
        _ = try await runtime.call(request)
    }
}

extension LocalMacComputer {
    func upload(_ source: URL, to path: String) async throws -> Int64 {
        try await LocalMacFileService(runtime: self).upload(source, to: path, progress: { _ in })
        return try await LocalMacFileService(runtime: self).stat(path).size
    }
    func download(_ path: String, to destination: URL) async throws -> Int64 {
        let service = LocalMacFileService(runtime: self)
        let file = try await service.stat(path)
        let manager = FileManager.default
        let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("download")
        try await service.read(file, path: path, to: staged, preview: false, progress: { _ in })
        if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: staged) }
        else { try manager.moveItem(at: staged, to: destination) }
        return file.size
    }
}
