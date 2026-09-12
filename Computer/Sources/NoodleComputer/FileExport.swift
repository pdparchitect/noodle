import ComputerCore
import CoreServices
import Foundation

protocol FileExportSource: Sendable {
    func list(_ path: String) async throws -> [GuestFile]
    func read(_ file: GuestFile, path: String, to destination: URL, preview: Bool,
              progress: @escaping @Sendable (Int64) -> Void) async throws
}

struct FileExportPlan: Sendable {
    struct Item: Sendable {
        let file: GuestFile
        let guestPath: String
        let components: [String]
    }
    let items: [Item]
    let totalBytes: Int64

    static func prepare(_ file: GuestFile, path: String, source: any FileExportSource) async throws -> Self {
        var pending = [Item(file: file, guestPath: try GuestFile.normalize(path), components: [])]
        var items: [Item] = []
        var totalBytes: Int64 = 0
        while let item = pending.popLast() {
            try Task.checkCancellation()
            try GuestFile.validateName(item.file.name)
            guard item.file.directory || item.file.regular else {
                throw ComputerError("“\(item.file.displayName)” is a symbolic link or special file and cannot be exported.")
            }
            guard item.file.size >= 0, item.file.directory || item.file.size <= FileImportPlan.fileLimit else {
                throw ComputerError("“\(item.file.displayName)” exceeds the 8 GB per-file export limit.")
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(item.file.regular ? item.file.size : 0)
            guard !overflow else { throw ComputerError("This folder is too large to export.") }
            totalBytes = sum; items.append(item)
            if item.file.directory {
                let children = try await source.list(item.guestPath)
                guard Set(children.map(\.name)).count == children.count else { throw ComputerError("Invalid folder listing.") }
                for child in children.reversed() {
                    pending.append(Item(file: child, guestPath: try GuestFile.path(item.guestPath, child.name), components: item.components + [child.name]))
                }
            }
        }
        return Self(items: items, totalBytes: totalBytes)
    }

    /// Keep guest content in a private staging tree until every file is complete.
    /// Cancellation/failure removes the entire unpublished export.
    func export(to destination: URL, source: any FileExportSource, stagingRoot: URL, replace: Bool,
                progress: @escaping @Sendable (FileTransferProgress) -> Void) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let free = try staging.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard Int64(free) - PreviewPolicy.cacheLimit > totalBytes else { throw ComputerError("There isn’t enough disk space to export this item.") }
        let root = staging.appendingPathComponent("item")
        var state = FileTransferProgress(totalItems: items.count, totalBytes: totalBytes)
        for item in items {
            try Task.checkCancellation()
            state.currentPath = ([items[0].file.name] + item.components).joined(separator: "/")
            progress(state)
            var url = item.components.reduce(root) { $0.appendingPathComponent($1) }
            if item.file.directory {
                try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } else {
                let before = state
                try await source.read(item.file, path: item.guestPath, to: url, preview: false) { bytes in
                    var current = before
                    current.transferredBytes += min(item.file.size, bytes)
                    progress(current)
                }
                state.transferredBytes += item.file.size
            }
            try Task.checkCancellation()
            var attributes = URLResourceValues()
            attributes.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                                                kLSQuarantineAgentNameKey as String: "Noodle Computer"]
            try url.setResourceValues(attributes)
            state.completedItems += 1
            progress(state)
        }
        try Task.checkCancellation()
        if replace, items.first?.file.regular == true, fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: root)
        } else { try fm.moveItem(at: root, to: destination) }
    }
}
