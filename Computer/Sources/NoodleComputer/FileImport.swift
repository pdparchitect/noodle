import ComputerCore
import Foundation

struct FileImportProgress: Sendable {
    var completedItems = 0
    let totalItems: Int
    var transferredBytes: Int64 = 0
    let totalBytes: Int64
    var currentPath = ""

    // Give empty files and directories work units too; publication completes each item.
    var fraction: Double {
        guard totalItems > 0 else { return 1 }
        return min(1, (Double(transferredBytes) + Double(completedItems)) / (Double(totalBytes) + Double(totalItems)))
    }
}

protocol FileImportDestination: Sendable {
    func createImportDirectory(_ path: String) async throws
    func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) async -> Void) async throws
}

struct FileImportPlan: Sendable {
    static let fileLimit: Int64 = 8 * 1024 * 1024 * 1024
    struct Item: Sendable {
        let source: URL
        let relativePath: String
        let destination: String
        let directory: Bool
        let size: Int64
    }
    let items: [Item]
    let totalBytes: Int64

    /// Called off the main actor, while the selected roots' security scopes are held.
    /// Preflight the whole selection so unsupported items don't leave a partial import.
    static func prepare(_ urls: [URL], folder: String) throws -> Self {
        let folder = try GuestFile.normalize(folder)
        var pending = try urls.reversed().map { url -> (URL, String, String) in
            guard url.isFileURL else { throw ComputerError("Choose local files or folders to import.") }
            return (url, url.lastPathComponent, try GuestFile.path(folder, url.lastPathComponent))
        }
        var items: [Item] = []
        var destinations = Set<String>()
        var totalBytes: Int64 = 0
        while let (source, relativePath, destination) = pending.popLast() {
            try Task.checkCancellation()
            guard destinations.insert(destination).inserted else {
                throw ComputerError("More than one selected item would import as “\(relativePath)”.")
            }
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else {
                throw ComputerError("“\(relativePath)” is a symbolic link. Import its original file or folder instead.")
            }
            let directory = values.isDirectory == true
            guard directory || (values.isRegularFile == true && values.fileSize != nil) else {
                throw ComputerError("“\(relativePath)” is not a regular file or folder.")
            }
            let size = directory ? 0 : Int64(values.fileSize!)
            guard size >= 0, size <= fileLimit else { throw ComputerError("“\(relativePath)” exceeds the 8 GB per-file import limit.") }
            let (sum, overflow) = totalBytes.addingReportingOverflow(size)
            guard !overflow else { throw ComputerError("The selected files are too large to import together.") }
            totalBytes = sum
            items.append(Item(source: source, relativePath: relativePath, destination: destination, directory: directory, size: size))
            if directory {
                // No hidden/package skips, and directory read failures must be reported.
                let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children.reversed() {
                    try Task.checkCancellation()
                    pending.append((child, relativePath + "/" + child.lastPathComponent, try GuestFile.path(destination, child.lastPathComponent)))
                }
            }
        }
        return Self(items: items, totalBytes: totalBytes)
    }

    func send(to destination: any FileImportDestination, progress: @escaping @Sendable (FileImportProgress) async -> Void) async throws {
        var state = FileImportProgress(totalItems: items.count, totalBytes: totalBytes)
        for item in items {
            try Task.checkCancellation()
            state.currentPath = item.relativePath
            await progress(state)
            try Task.checkCancellation()
            if item.directory {
                try await destination.createImportDirectory(item.destination)
            } else {
                var source = item.source
                source.removeAllCachedResourceValues()
                guard let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == item.size else {
                    throw ComputerError("“\(item.relativePath)” changed after preparing the import. Try importing it again.")
                }
                let before = state
                try await destination.upload(source, to: item.destination) { bytes in
                    var current = before
                    current.transferredBytes += min(item.size, bytes)
                    await progress(current)
                }
                state.transferredBytes += item.size
            }
            state.completedItems += 1
            await progress(state)
        }
        try Task.checkCancellation()
    }
}
