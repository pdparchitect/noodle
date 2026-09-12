import AppKit
import ComputerCore
import CryptoKit
import Foundation

@MainActor enum ComputerFilesSmokeTest {
    static func run() async throws -> ComputerStore {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleFiles-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        print("FILES: preparing disposable guest at \(root.path)")
        let computer = Computer(name: "Files preview", kind: .container, cpuCount: 2, memoryGiB: 1,
                                diskGiB: 4, networkEnabled: false, imageReference: "docker.io/library/alpine:3.23.5", customImage: true)
        do {
            guard await store.create(computer, source: nil), let session = store.selected else { throw ComputerError(store.error ?? "Could not create files fixture") }
            if session.phase != .running { await store.start(session) }
            guard let runtime = session.container, session.phase == .running else { throw ComputerError("Fixture did not start") }
            let files = GuestFiles(runtime: runtime)
            let source = root.appendingPathComponent("source.bin")
            let bytes = Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0) })
            try bytes.write(to: source)
            let unusual = "quotes ' and $(literal)\n.bin"
            try await files.upload(source, to: GuestFile.path("/workspace", unusual))
            var listing = try await files.list("/workspace")
            guard let binary = listing.first(where: { $0.name == unusual }) else { throw ComputerError("Filename did not round trip") }
            let result = root.appendingPathComponent("download.bin")
            try await files.read(binary, path: GuestFile.path("/workspace", unusual), to: result, preview: false)
            guard try Data(contentsOf: result) == bytes else { throw ComputerError("Binary transfer was corrupted") }
            print("PASS: binary upload/export and literal punctuation/newline filenames")
            let browser = session.filesModel(for: runtime)
            let promised = root.appendingPathComponent("Promised", isDirectory: true)
            try FileManager.default.createDirectory(at: promised, withIntermediateDirectories: false)
            let promiseDelegate = FileExportPromise(model: browser, file: binary, path: try GuestFile.path("/workspace", unusual))
            let provider = NSFilePromiseProvider(fileType: "public.data", delegate: promiseDelegate)
            provider.userInfo = promiseDelegate
            let received = promised.appendingPathComponent(unusual)
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                promiseDelegate.filePromiseProvider(provider, writePromiseTo: received) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            guard try Data(contentsOf: received) == bytes else { throw ComputerError("Promised file was corrupted") }
            print("PASS: file-promise export callback writes exact guest bytes")
            do { try await files.upload(source, to: GuestFile.path("/workspace", unusual)); throw ComputerError("TEST: overwrite was allowed") }
            catch { if error.localizedDescription.hasPrefix("TEST:") { throw error } }
            try await files.change("mkdir", path: "/workspace/Documents")
            try await files.change("copy", path: GuestFile.path("/workspace", unusual), extra: [binary.version, "/workspace/Documents/Copy.bin"])
            try await files.change("rename", path: "/workspace/Documents/Copy.bin", extra: ["/workspace/Documents/Moved.bin"])
            try await files.change("remove", path: "/workspace/Documents/Moved.bin")
            print("PASS: no-overwrite imports, folder creation, duplicate, move and deletion")
            browser.importFiles([source], into: "/workspace/Documents")
            while browser.busy { try await Task.sleep(for: .milliseconds(20)) }
            guard browser.error == nil, try await files.list("/workspace/Documents").contains(where: { $0.name == "source.bin" }),
                  !(try await files.list("/workspace").contains(where: { $0.name == "source.bin" })) else { throw ComputerError("Import ignored the drop target folder") }
            print("PASS: imports use the explicit folder drop target")
            let importFolder = root.appendingPathComponent("Imported Folder")
            try FileManager.default.createDirectory(at: importFolder.appendingPathComponent("Nested/Empty"), withIntermediateDirectories: true)
            try bytes.write(to: importFolder.appendingPathComponent("Nested/bytes.bin"))
            try Data().write(to: importFolder.appendingPathComponent(".hidden"))
            try await files.importItems([importFolder], to: "/workspace") { _ in }
            let imported = try await files.list("/workspace/Imported Folder/Nested")
            guard imported.contains(where: { $0.name == "Empty" && $0.directory }),
                  let importedFile = imported.first(where: { $0.name == "bytes.bin" }) else { throw ComputerError("Nested folder import was incomplete") }
            let importedBytes = root.appendingPathComponent("imported.bin")
            try await files.read(importedFile, path: "/workspace/Imported Folder/Nested/bytes.bin", to: importedBytes, preview: false)
            guard try Data(contentsOf: importedBytes) == bytes,
                  try await files.list("/workspace/Imported Folder").contains(where: { $0.name == ".hidden" }) else { throw ComputerError("Folder contents did not round trip") }
            do { try await files.importItems([importFolder], to: "/workspace") { _ in }; throw ComputerError("TEST: folder import merged an existing folder") }
            catch { if error.localizedDescription.hasPrefix("TEST:") { throw error } }
            print("PASS: nested, empty and hidden folder contents; existing folders are not merged")

            guard let importedFolder = try await files.list("/workspace").first(where: { $0.name == "Imported Folder" }),
                  let folderPromise = FileExportPromise.provider(model: browser, file: importedFolder),
                  folderPromise.fileType == "public.folder",
                  let folderDelegate = folderPromise.userInfo as? FileExportPromise else { throw ComputerError("Folder drag did not offer a folder promise") }
            let exportedFolder = root.appendingPathComponent("Exported Folder")
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                folderDelegate.filePromiseProvider(folderPromise, writePromiseTo: exportedFolder) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            guard try Data(contentsOf: exportedFolder.appendingPathComponent("Nested/bytes.bin")) == bytes,
                  FileManager.default.fileExists(atPath: exportedFolder.appendingPathComponent("Nested/Empty").path),
                  FileManager.default.fileExists(atPath: exportedFolder.appendingPathComponent(".hidden").path) else { throw ComputerError("Folder promise export was incomplete") }
            print("PASS: Finder folder promise preserves nested, hidden and empty contents")

            let cancelFolder = root.appendingPathComponent("Cancelled Import")
            try FileManager.default.createDirectory(at: cancelFolder, withIntermediateDirectories: false)
            try Data([1]).write(to: cancelFolder.appendingPathComponent("a-completed"))
            let largeImport = cancelFolder.appendingPathComponent("b-incomplete")
            try Data().write(to: largeImport)
            let largeHandle = try FileHandle(forWritingTo: largeImport)
            try largeHandle.truncate(atOffset: 32 * 1024 * 1024)
            try largeHandle.close()
            try Data([2]).write(to: cancelFolder.appendingPathComponent("c-later"))
            let cancellation = FileImportSmokeCancellation()
            let cancelledImport = Task {
                try await files.importItems([cancelFolder], to: "/workspace") { progress in
                    if progress.currentPath.hasSuffix("b-incomplete"), progress.transferredBytes > 1 { await cancellation.cancel() }
                }
            }
            await cancellation.setTask(cancelledImport)
            do { try await cancelledImport.value; throw ComputerError("TEST: cancelled folder import succeeded") }
            catch { if error.localizedDescription.hasPrefix("TEST:") { throw error } }
            let cancelledItems = try await files.list("/workspace/Cancelled Import")
            guard cancelledItems.map(\.name) == ["a-completed"] else { throw ComputerError("Cancellation left partial bytes or imported later files") }
            print("PASS: cancellation keeps completed files and removes unfinished upload bytes")
            try await files.upload(largeImport, to: "/workspace/Imported Folder/Nested/large.bin")
            let exportPlan = try await FileExportPlan.prepare(importedFolder, path: "/workspace/Imported Folder", source: files)
            let exportCancellation = FileExportSmokeCancellation()
            let cancelledDestination = root.appendingPathComponent("Cancelled Export")
            let cancelledExport = Task {
                try await exportPlan.export(to: cancelledDestination, source: files, stagingRoot: FileExportStaging.root, replace: false) { progress in
                    if progress.currentPath.hasSuffix("large.bin"), progress.transferredBytes > Int64(bytes.count) { exportCancellation.cancel() }
                }
            }
            exportCancellation.setTask(cancelledExport)
            do { try await cancelledExport.value; throw ComputerError("TEST: cancelled folder export succeeded") }
            catch { if error.localizedDescription.hasPrefix("TEST:") { throw error } }
            guard !FileManager.default.fileExists(atPath: cancelledDestination.path),
                  try FileManager.default.contentsOfDirectory(atPath: FileExportStaging.root.path).isEmpty else { throw ComputerError("Cancelled export left host files or staging") }
            print("PASS: cancelling folder export removes its private staging and publishes no partial folder")
            _ = try await runtime.execute("printf 'Welcome to Files\\n\\nBrowse, drag files in and out, and press Space for Quick Look.\\n' > /workspace/Welcome.txt; ln -s /workspace/Welcome.txt /workspace/link.txt; mkfifo /workspace/pipe.txt; truncate -s 22020096 /workspace/Large.txt")
            listing = try await files.list("/workspace")
            for name in ["link.txt", "pipe.txt", "Large.txt"] {
                guard let item = listing.first(where: { $0.name == name }) else { throw ComputerError("Missing test file") }
                // Forge regular-file metadata to exercise the guest's fstat/no-follow check.
                let forged = GuestFile(name: item.name, kind: "file", size: item.size, modified: item.modified, version: item.version)
                do { try await files.read(forged, path: "/workspace/" + name, to: root.appendingPathComponent("reject-" + name), preview: true); throw ComputerError("TEST: unsafe preview succeeded") }
                catch { if error.localizedDescription.hasPrefix("TEST:") { throw error } }
            }
            print("PASS: oversized previews, symlinks and FIFOs rejected")
            guard let welcome = listing.first(where: { $0.name == "Welcome.txt" }) else { throw ComputerError("Missing preview document") }
            let lease = try await FilePreviewCache.shared.acquire(key: UUID().uuidString, size: welcome.size, suffix: "txt")
            try await files.read(welcome, path: "/workspace/Welcome.txt", to: lease.url, preview: true)
            try PreviewPolicy.validate(lease.url)
            await FilePreviewCache.shared.complete(lease)
            await FilePreviewCache.shared.release(lease)
            _ = try await runtime.execute("printf 'changed' >> /workspace/Welcome.txt")
            do { try await files.read(welcome, path: "/workspace/Welcome.txt", to: root.appendingPathComponent("stale"), preview: true); throw ComputerError("TEST: stale file was accepted") }
            catch { if error.localizedDescription.hasPrefix("TEST:") { throw error } }
            print("PASS: bounded preview cache, text validation and stale-file rejection")
            // Valid PNG/PDF fixtures allow visual verification of actual Quick Look.
            let image = NSImage(size: NSSize(width: 640, height: 400))
            image.lockFocus()
            NSColor.systemIndigo.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 400)).fill()
            NSString(string: "Noodle Files").draw(at: NSPoint(x: 55, y: 180), withAttributes: [.font: NSFont.systemFont(ofSize: 58, weight: .bold), .foregroundColor: NSColor.white])
            image.unlockFocus()
            let png = root.appendingPathComponent("Preview.png")
            try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: png)
            try await files.upload(png, to: "/workspace/Preview.png")
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); text.string = "Noodle Files\n\nNative PDF preview"; text.font = .systemFont(ofSize: 26)
            let pdf = root.appendingPathComponent("Preview.pdf")
            try text.dataWithPDF(inside: text.bounds).write(to: pdf)
            try await files.upload(pdf, to: "/workspace/Preview.pdf")
            session.showingFiles = true
            print("FILES FIXTURE: \(root.path)")
            if !CommandLine.arguments.contains("--keep-test-window") {
                await store.shutdown(); try FileManager.default.removeItem(at: root)
                print("PASS: disposable file fixture stopped and removed")
            }
            return store
        } catch {
            await store.shutdown()
            print("Files fixture retained for diagnosis: \(root.path)")
            throw error
        }
    }
}

private actor FileImportSmokeCancellation {
    private var task: Task<Void, Error>?
    func setTask(_ task: Task<Void, Error>) { self.task = task }
    func cancel() { task?.cancel(); task = nil }
}

private final class FileExportSmokeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    func setTask(_ task: Task<Void, Error>) { lock.withLock { self.task = task } }
    func cancel() {
        let task = lock.withLock { let task = self.task; self.task = nil; return task }
        task?.cancel()
    }
}
