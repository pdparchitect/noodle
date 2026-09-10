// Adapted from ChatBotKit Studio's StorageMaintenance.swift.
// Copyright 2026 CBK.AI LTD. Licensed under Apache-2.0.
import ComputerCore
import Containerization
import ContainerizationOCI
import Foundation

struct StorageReport: Sendable {
    let freeBytes: Int64
    let cacheBytes: Int64
    let runtimeBytes: Int64
    let computerBytes: Int64
    let orphanedBytes: UInt64
    let obsoleteImages: [String]
    let obsoleteFiles: [String]
    let runtimeSnapshot: [String: StorageMaintenance.FileStamp]
    let protectedImages: Set<String>?

    var removableCount: Int { obsoleteImages.count + obsoleteFiles.count }
    var canClean: Bool { removableCount > 0 || orphanedBytes > 0 }
}

enum StorageMaintenance {
    struct FileStamp: Equatable, Sendable {
        let bytes: Int64
        let allocated: Int64
        let modified: Date?
        let inode: UInt64
    }

    /// Reject links, including directory links, before handing paths to ImageStore
    /// or recursive removal. The store's lifetime library lease excludes other apps.
    static func snapshot(at root: URL) throws -> [String: FileStamp] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey]
        func visit(_ url: URL, relative: String, into files: inout [String: FileStamp]) throws {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw ComputerError("Storage inspection refused a linked path: \(url.lastPathComponent).")
            }
            if values.isDirectory == true {
                for child in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)) {
                    try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent, into: &files)
                }
            } else if values.isRegularFile == true {
                let attributes = try manager.attributesOfItem(atPath: url.path)
                files[relative] = FileStamp(bytes: Int64(values.fileSize ?? 0),
                    allocated: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                    modified: values.contentModificationDate,
                    inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
            } else {
                throw ComputerError("Storage inspection found an unexpected file: \(url.lastPathComponent).")
            }
        }
        // attributesOfItem also detects dangling symlinks that fileExists misses.
        do { _ = try manager.attributesOfItem(atPath: root.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
        var files: [String: FileStamp] = [:]
        try visit(root, relative: "", into: &files)
        return files
    }

    static func normalized(_ reference: String) throws -> String {
        let parsed = try Reference.parse(reference)
        parsed.normalize()
        return parsed.description
    }

    static func protectedImages(library: ComputerLibrary) throws -> Set<String>? {
        var keep = try Set([ContainerComputer.initReference, Computer.shellImage].map(normalized))
        for computer in try library.load() where computer.kind == .container {
            keep.insert(try normalized(computer.imageReference))
            let directory = library.directory(for: computer.id)
            // Missing/corrupt recovery metadata means we cannot prove an image unused.
            guard let state = try? ContainerDiskState.load(in: directory) else { return nil }
            keep.insert(state.imageDigest)
            if let previous = state.previousGeneration {
                let file = directory.appendingPathComponent("Layers/\(previous.uuidString.lowercased())/State.json")
                guard let data = try? Data(contentsOf: file),
                      let recovery = try? JSONDecoder().decode(ContainerDiskState.self, from: data),
                      recovery.generation == previous else { return nil }
                keep.insert(recovery.imageDigest)
            }
        }
        return keep
    }

    static func removableFiles(in files: [String: FileStamp]) -> [String] {
        files.keys.filter { path in
            let parts = path.split(separator: "/")
            // Only downloaded installers and their records; never arbitrary Runtime files.
            guard parts.count == 2, ["Restore Images", "Linux Images"].contains(String(parts[0])) else { return false }
            return parts[1].range(of: "^[a-f0-9]{64}\\.(iso|ipsw)(\\.json)?$", options: .regularExpression) != nil
        }.sorted()
    }

    static func inspect(library: ComputerLibrary) async throws -> StorageReport {
        let runtime = library.root.appendingPathComponent("Runtime")
        // Validate ancestors and every file before reading image or recovery metadata.
        let allFiles = try snapshot(at: library.root)
        let keep = try protectedImages(library: library)
        let imagePath = runtime.appendingPathComponent("Images")
        var obsolete: [String] = []
        var orphaned: UInt64 = 0
        if FileManager.default.fileExists(atPath: imagePath.path) {
            let images = try ImageStore(path: imagePath)
            if let keep {
                obsolete = try await images.list().filter {
                    !keep.contains(try normalized($0.reference)) && !keep.contains($0.digest)
                }.map(\.reference).sorted()
                orphaned = try await images.calculateOrphanedBlobsSize()
            }
        }
        // ImageStore can initialize bookkeeping. Capture the preview after opening it.
        let files = try snapshot(at: runtime)
        let cacheBytes = files.filter { name, _ in
            name.hasPrefix("Images/") || name.hasPrefix("Restore Images/") || name.hasPrefix("Linux Images/")
        }.values.reduce(Int64(0)) { $0 + $1.allocated }
        let capacity = try library.root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let filesystem = try FileManager.default.attributesOfFileSystem(forPath: library.root.path)
        guard let freeBytes = capacity.volumeAvailableCapacity.map(Int64.init)
            ?? (filesystem[.systemFreeSize] as? NSNumber)?.int64Value else {
            throw ComputerError("Could not determine available disk space.")
        }
        return StorageReport(freeBytes: freeBytes,
            cacheBytes: cacheBytes,
            runtimeBytes: files.values.reduce(Int64(0)) { $0 + $1.allocated } - cacheBytes,
            computerBytes: allFiles.filter { $0.key.hasPrefix("Computers/") || $0.key.hasPrefix("Staging/") }
                .values.reduce(Int64(0)) { $0 + $1.allocated },
            orphanedBytes: orphaned, obsoleteImages: obsolete, obsoleteFiles: removableFiles(in: files),
            runtimeSnapshot: files, protectedImages: keep)
    }

    static func clean(library: ComputerLibrary, preview: StorageReport) async throws -> String {
        let current = try await inspect(library: library)
        guard current.runtimeSnapshot == preview.runtimeSnapshot,
              current.protectedImages == preview.protectedImages,
              current.obsoleteImages == preview.obsoleteImages,
              current.obsoleteFiles == preview.obsoleteFiles else {
            throw ComputerError("The cache changed since the preview. Refresh Storage before cleaning it.")
        }
        try Task.checkCancellation()
        let runtime = library.root.appendingPathComponent("Runtime")
        let imagePath = runtime.appendingPathComponent("Images")
        var freed: UInt64 = 0
        if current.protectedImages != nil, FileManager.default.fileExists(atPath: imagePath.path) {
            let images = try ImageStore(path: imagePath)
            for reference in current.obsoleteImages {
                try await images.delete(reference: reference, performCleanup: false)
            }
            freed = try await images.cleanUpOrphanedBlobs().freed
        }
        for name in current.obsoleteFiles {
            try FileManager.default.removeItem(at: runtime.appendingPathComponent(name))
        }
        return "Removed \(current.removableCount) cached items; reclaimed \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .file)) of image blobs. Removed caches can be downloaded again. Computer disks and recovery copies were preserved."
    }
}
