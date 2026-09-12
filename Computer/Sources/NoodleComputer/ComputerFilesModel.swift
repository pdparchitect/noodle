import AppKit
import ComputerCore
import Foundation
import CoreServices

@MainActor final class ComputerFilesModel: ObservableObject {
    let service: GuestFiles
    let computerID: UUID
    @Published var folder = "/workspace"
    @Published var files: [GuestFile] = []
    @Published var selection: String?
    @Published var loading = false
    @Published var busy = false
    @Published var importProgress: FileImportProgress?
    @Published var cancellingTransfer = false
    @Published var status = ""
    @Published var error: String?
    @Published var previewURL: URL?
    @Published var previewStatus = "Select a file to preview"
    @Published var showHidden = false
    @Published var iconView = true
    @Published var previewEnabled = false
    @Published var filter = ""
    @Published var history: [String] = []
    @Published var forwardHistory: [String] = []
    private var listing: Task<Void, Never>?
    private var preview: Task<Void, Never>?
    private var transfer: Task<Void, Never>?
    private var lease: FilePreviewCache.Lease?
    private var listingID = UUID()
    private var previewID = UUID()

    init(runtime: ContainerComputer, computerID: UUID) { service = GuestFiles(runtime: runtime); self.computerID = computerID }
    var selected: GuestFile? { files.first { $0.name == selection } }
    var visible: [GuestFile] { files.filter { (showHidden || !$0.name.hasPrefix(".")) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) } }
    var parent: String { folder == "/" ? "/" : (folder as NSString).deletingLastPathComponent }

    func navigate(_ path: String, record: Bool = true, selecting: String? = nil, clearStatus: Bool = true) {
        let destination: String
        do { destination = try GuestFile.normalize(path) } catch { self.error = error.localizedDescription; return }
        listing?.cancel()
        stopPreview(); selection = nil
        loading = true
        let id = UUID(); listingID = id
        listing = Task {
            do {
                let items = try await service.list(destination)
                try Task.checkCancellation()
                guard listingID == id else { return }
                if record, folder != destination { history.append(folder); forwardHistory = [] }
                folder = destination; files = items; filter = ""
                if clearStatus, !busy { status = "" }
                if let selected = items.first(where: { $0.name == selecting }) ?? (previewEnabled ? visible.first : nil) { choose(selected) }
            } catch {
                if !Task.isCancelled, listingID == id { self.error = error.localizedDescription }
            }
            if listingID == id { loading = false }
        }
    }
    func goUp() { guard folder != "/" else { return }; navigate(parent, selecting: (folder as NSString).lastPathComponent) }
    func back() { guard let path = history.popLast() else { return }; forwardHistory.append(folder); navigate(path, record: false) }
    func forward() { guard let path = forwardHistory.popLast() else { return }; history.append(folder); navigate(path, record: false) }
    func choose(_ file: GuestFile?) {
        selection = file?.name
        if previewEnabled { loadPreview() } else { stopPreview() }
    }
    func open(_ file: GuestFile) { if file.directory, let path = try? GuestFile.path(folder, file.name) { navigate(path) } }

    func stopPreview() {
        previewID = UUID(); preview?.cancel(); preview = nil; previewURL = nil
        if let lease { self.lease = nil; Task { await FilePreviewCache.shared.release(lease) } }
    }
    func loadPreview() {
        stopPreview()
        guard let file = selected else { previewStatus = "Select a file to preview"; return }
        guard file.regular else { previewStatus = file.directory ? "Folder" : "Preview unavailable for this item"; return }
        guard file.size <= PreviewPolicy.fileLimit else { previewStatus = "Preview unavailable · larger than 20 MB"; return }
        guard let suffix = PreviewPolicy.suffix(for: file.name) else { previewStatus = "Preview unavailable for this file type"; return }
        guard let path = try? GuestFile.path(folder, file.name) else { return }
        previewStatus = "Loading preview…"
        let id = UUID(); previewID = id
        preview = Task {
            var acquired: FilePreviewCache.Lease?
            do {
                let lease = try await FilePreviewCache.shared.acquire(key: "\(computerID)|\(path)|\(file.version)", size: file.size, suffix: suffix, name: file.name)
                acquired = lease
                if !lease.reused {
                    try await service.read(file, path: path, to: lease.url, preview: true)
                    try PreviewPolicy.validate(lease.url)
                    await FilePreviewCache.shared.complete(lease)
                }
                try Task.checkCancellation()
                guard previewID == id else { throw CancellationError() }
                self.lease = lease; previewURL = lease.url; previewStatus = ""
            } catch {
                if let acquired { await FilePreviewCache.shared.release(acquired) }
                if !Task.isCancelled, previewID == id { previewStatus = "Preview unavailable · refresh to retry" }
            }
        }
    }

    func perform(_ message: String, cancellationMessage: String = "Cancelled", action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; status = message; importProgress = nil; cancellingTransfer = false
        transfer = Task {
            do { try await action(); try Task.checkCancellation(); status = "Done" }
            catch {
                let cancelled = Task.isCancelled || error is CancellationError
                if !cancelled { self.error = error.localizedDescription }
                status = cancelled ? cancellationMessage : "Could not complete operation"
            }
            busy = false; transfer = nil; importProgress = nil; cancellingTransfer = false
            navigate(folder, record: false, clearStatus: false)
        }
    }
    func cancelTransfer() {
        guard busy, !cancellingTransfer else { return }
        cancellingTransfer = true; status = "Cancelling…"; transfer?.cancel()
    }
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let folder = folder
        perform("Preparing import…", cancellationMessage: "Import cancelled. Completed items were kept.") {
            try await self.service.importItems(urls, to: folder) { [weak self] progress in
                await self?.updateImportProgress(progress)
            }
        }
    }
    private func updateImportProgress(_ progress: FileImportProgress) {
        guard busy, !cancellingTransfer else { return }
        importProgress = progress; status = "Importing \(progress.currentPath)"
    }
    func importPanel() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.begin { [weak self] response in if response == .OK { self?.importFiles(panel.urls) } }
    }
    func exportPanel() {
        guard let file = selected, file.regular, let path = try? GuestFile.path(folder, file.name) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name; panel.prompt = "Export"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.perform("Exporting \(file.name)…") { try await self.export(file, path: path, to: url, replace: true) }
        }
    }
    func export(_ file: GuestFile, path: String, to destination: URL, replace: Bool) async throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        try FileExportStaging.prepare()
        let staging = FileExportStaging.root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let free = try staging.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard Int64(free) > file.size + PreviewPolicy.cacheLimit else { throw ComputerError("There isn’t enough disk space to export this file.") }
        var source = staging.appendingPathComponent("file")
        try await service.read(file, path: path, to: source, preview: false)
        try Task.checkCancellation()
        var attributes = URLResourceValues()
        attributes.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                                            kLSQuarantineAgentNameKey as String: "Noodle Computer"]
        try source.setResourceValues(attributes)
        if replace, fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else { try fm.moveItem(at: source, to: destination) }
    }
    func promisedExport(_ file: GuestFile, path: String, to destination: URL, completion: @escaping (Error?) -> Void) {
        guard !busy else { completion(ComputerError("Wait for the current transfer to finish.")); return }
        perform("Exporting \(file.name)…") {
            do { try await self.export(file, path: path, to: destination, replace: false); completion(nil) }
            catch { completion(error); throw error }
        }
    }
    func createFolder(_ name: String) {
        do { let path = try GuestFile.path(folder, name); perform("Creating folder…") { try await self.service.change("mkdir", path: path) } }
        catch { self.error = error.localizedDescription }
    }
    func rename(_ name: String) {
        guard let file = selected else { return }
        do {
            let old = try GuestFile.path(folder, file.name), new = try GuestFile.path(folder, name)
            perform("Renaming…") { try await self.service.change("rename", path: old, extra: [new]) }
        } catch { self.error = error.localizedDescription }
    }
    func removeSelected() {
        guard let file = selected, let path = try? GuestFile.path(folder, file.name) else { return }
        perform("Deleting…") { try await self.service.change("remove", path: path) }
    }
    func duplicateSelected() {
        guard let file = selected, file.regular else { return }
        do {
            let source = try GuestFile.path(folder, file.name)
            let destination = try GuestFile.path(folder, "Copy of " + file.name)
            perform("Duplicating…") { try await self.service.change("copy", path: source, extra: [file.version, destination]) }
        } catch { self.error = error.localizedDescription }
    }
    func move(_ file: GuestFile, into directory: GuestFile) {
        guard directory.directory, file.name != directory.name else { return }
        do {
            let source = try GuestFile.path(folder, file.name)
            let destination = try GuestFile.path(GuestFile.path(folder, directory.name), file.name)
            perform("Moving…") { try await self.service.change("rename", path: source, extra: [destination]) }
        } catch { self.error = error.localizedDescription }
    }
    func disappear() { listing?.cancel(); stopPreview() }
    deinit { listing?.cancel(); preview?.cancel(); transfer?.cancel() }
}

@MainActor enum FileExportStaging {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Noodle File Exports", isDirectory: true)
    private static var prepared = false
    static func prepare() throws {
        let fm = FileManager.default
        if !prepared {
            if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
            prepared = true
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
