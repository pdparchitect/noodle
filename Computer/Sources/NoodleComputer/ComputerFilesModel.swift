import AppKit
import ComputerCore
import Foundation

@MainActor final class ComputerFilesModel: ObservableObject {
    let service: any ComputerFileService
    let computerID: UUID
    @Published var folder = "/workspace"
    @Published var files: [GuestFile] = []
    @Published var selection: Set<String> = []
    @Published var loading = false
    @Published var busy = false
    @Published var transferProgress: FileTransferProgress?
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
    private var transferID = UUID()
    private var queuedExports: [(start: () -> Void, cancel: () -> Void)] = []

    init(service: any ComputerFileService, computerID: UUID) {
        self.service = service; self.computerID = computerID
    }
    convenience init(runtime: ContainerComputer, computerID: UUID) { self.init(service: GuestFiles(runtime: runtime), computerID: computerID) }
    /// Only what is shown counts, so a search or hiding dotfiles cannot leave unseen items to be deleted.
    var selectedFiles: [GuestFile] { visible.filter { selection.contains($0.name) } }
    /// The single chosen item, for actions that only make sense on one (rename, preview, Quick Look).
    var selected: GuestFile? { let files = selectedFiles; return files.count == 1 ? files[0] : nil }
    var visible: [GuestFile] { files.filter { (showHidden || !$0.name.hasPrefix(".")) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) } }
    var emptyFolder: EmptyFolder? { loading ? nil : EmptyFolder(files: files, showHidden: showHidden, filter: filter) }
    var parent: String { folder == "/" ? "/" : (folder as NSString).deletingLastPathComponent }

    /// Why the listing shows nothing, so the view can say so instead of looking blank.
    enum EmptyFolder: Equatable {
        case empty, hiddenOnly, noMatches
        init?(files: [GuestFile], showHidden: Bool, filter: String) {
            let shown = files.filter { showHidden || !$0.name.hasPrefix(".") }
            if files.isEmpty { self = .empty }
            else if shown.isEmpty { self = .hiddenOnly }
            else if !filter.isEmpty, !shown.contains(where: { $0.name.localizedCaseInsensitiveContains(filter) }) { self = .noMatches }
            else { return nil }
        }
    }

    func navigate(_ path: String, record: Bool = true, selecting: String? = nil, clearStatus: Bool = true) {
        let destination: String
        do { destination = try GuestFile.normalize(path) } catch { self.error = error.localizedDescription; return }
        navigate(resolving: { destination }, record: record, selecting: selecting, clearStatus: clearStatus)
    }
    func goHome() { navigate(resolving: { [service] in try await service.homeDirectory() }) }
    private func navigate(resolving destination: @escaping () async throws -> String,
                          record: Bool = true, selecting: String? = nil, clearStatus: Bool = true) {
        listing?.cancel()
        stopPreview(); selection = []
        loading = true
        let id = UUID(); listingID = id
        listing = Task {
            do {
                let destination = try GuestFile.normalize(await destination())
                try Task.checkCancellation()
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
    func choose(_ file: GuestFile?) { select(file.map { [$0.name] } ?? []) }
    func select(_ names: Set<String>) {
        selection = names
        if previewEnabled { loadPreview() } else { stopPreview() }
    }
    /// Right-clicking outside the selection acts on the clicked item alone, as in Finder.
    func prepareContextMenu(for file: GuestFile?) {
        guard let file else { if !selection.isEmpty { select([]) }; return }
        if !selection.contains(file.name) { choose(file) }
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
        busy = true; status = message; transferProgress = nil; cancellingTransfer = false; transferID = UUID()
        transfer = Task {
            do { try await action(); try Task.checkCancellation(); status = "Done" }
            catch {
                let cancelled = Task.isCancelled || error is CancellationError
                if !cancelled { self.error = error.localizedDescription }
                status = cancelled ? cancellationMessage : "Could not complete operation"
            }
            busy = false; transfer = nil; transferProgress = nil; cancellingTransfer = false
            if !queuedExports.isEmpty { queuedExports.removeFirst().start(); return }
            navigate(folder, record: false, clearStatus: false)
        }
    }
    func cancelTransfer() {
        guard busy, !cancellingTransfer else { return }
        cancellingTransfer = true; status = "Cancelling…"; transfer?.cancel()
        let queued = queuedExports; queuedExports = []
        for export in queued { export.cancel() }
    }
    func importFiles(_ urls: [URL], into destination: String? = nil) {
        guard !urls.isEmpty else { return }
        let folder = destination ?? folder
        perform("Preparing import…", cancellationMessage: "Import cancelled. Completed items were kept.") { [self] in
            let id = self.transferID
            try await self.service.importItems(urls, to: folder) { [weak self] progress in
                await self?.updateTransferProgress(progress, verb: "Importing", id: id)
            }
        }
    }
    private func updateTransferProgress(_ progress: FileTransferProgress, verb: String, id: UUID) {
        guard busy, !cancellingTransfer, transferID == id else { return }
        if let previous = transferProgress,
           progress.completedItems < previous.completedItems || progress.transferredBytes < previous.transferredBytes { return }
        transferProgress = progress; status = "\(verb) \(progress.currentPath)"
    }
    func importPanel() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.begin { [weak self] response in if response == .OK { self?.importFiles(panel.urls) } }
    }
    func exportPanel() {
        let files = selectedFiles.filter { $0.regular || $0.directory }
        if files.count > 1 {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.prompt = "Export Here"; panel.message = "Choose where to export \(files.count) items."
            panel.begin { [weak self] response in if response == .OK, let parent = panel.url { self?.exportSelected(into: parent) } }
            return
        }
        guard let file = files.first, file.regular || file.directory, let path = try? GuestFile.path(folder, file.name) else { return }
        if file.directory {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.prompt = "Export Here"; panel.message = "Choose where to export “\(file.displayName)”."
            panel.begin { [weak self] response in
                guard response == .OK, let parent = panel.url, let self else { return }
                self.perform("Preparing export…") {
                    let scoped = parent.startAccessingSecurityScopedResource()
                    defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
                    try await self.export(file, path: path, to: parent.appendingPathComponent(file.name), replace: false)
                }
            }
            return
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name; panel.prompt = "Export"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.perform("Exporting \(file.name)…") { try await self.export(file, path: path, to: url, replace: true) }
        }
    }
    func exportSelected(into parent: URL) {
        let folder = folder, files = selectedFiles.filter { $0.regular || $0.directory }
        guard !files.isEmpty else { return }
        perform("Preparing export…") {
            let scoped = parent.startAccessingSecurityScopedResource()
            defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
            for file in files {
                try await self.export(file, path: try GuestFile.path(folder, file.name), to: parent.appendingPathComponent(file.name), replace: false)
            }
        }
    }
    func export(_ file: GuestFile, path: String, to destination: URL, replace: Bool) async throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        try FileExportStaging.prepare()
        let id = transferID
        let plan = try await FileExportPlan.prepare(file, path: path, source: service)
        try await plan.export(to: destination, source: service, stagingRoot: FileExportStaging.root, replace: replace) { [weak self] progress in
            Task { @MainActor in self?.updateTransferProgress(progress, verb: "Exporting", id: id) }
        }
    }
    func promisedExport(_ file: GuestFile, path: String, to destination: URL, completion: @escaping (Error?) -> Void) {
        // Dragging several items out promises each one separately; run them one after another.
        let start = { [weak self] in
            guard let self else { completion(CancellationError()); return }
            self.perform("Exporting \(file.name)…") {
                do { try await self.export(file, path: path, to: destination, replace: false); completion(nil) }
                catch { completion(error); throw error }
            }
        }
        if busy { queuedExports.append((start, { completion(CancellationError()) })) } else { start() }
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
        let items = selectedFiles.compactMap { file in (try? GuestFile.path(folder, file.name)).map { (file, $0) } }
        guard !items.isEmpty else { return }
        perform("Deleting…") {
            // Check every folder first so a refused one does not leave the batch half deleted.
            for (file, path) in items where file.directory {
                if try await !self.service.list(path).isEmpty { throw ComputerError("“\(file.displayName)” is not empty. Nonempty folders cannot be deleted here.") }
            }
            for (_, path) in items { try await self.service.change("remove", path: path) }
        }
    }
    func duplicateSelected() {
        do {
            let copies = try selectedFiles.filter(\.regular).map { file in
                (source: try GuestFile.path(folder, file.name), version: file.version, destination: try GuestFile.path(folder, "Copy of " + file.name))
            }
            guard !copies.isEmpty else { return }
            perform("Duplicating…") {
                for copy in copies { try await self.service.change("copy", path: copy.source, extra: [copy.version, copy.destination]) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func move(_ files: [GuestFile], intoFolder destinationFolder: String) {
        do {
            let parent = try GuestFile.normalize(destinationFolder)
            guard parent != folder else { return }
            let moves = try files.compactMap { file -> (String, String)? in
                let source = try GuestFile.path(folder, file.name)
                guard parent != source, !parent.hasPrefix(source + "/") else { return nil }
                return (source, try GuestFile.path(parent, file.name))
            }
            guard !moves.isEmpty else { return }
            perform("Moving…") { for (source, destination) in moves { try await self.service.change("rename", path: source, extra: [destination]) } }
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
