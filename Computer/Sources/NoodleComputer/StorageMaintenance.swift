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
    let sharedBytes: Int64
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

    /// Bytes each file alone holds, plus blocks shared between APFS clones counted once. Allocated
    /// sizes count a clone's shared blocks in every copy, so duplicated disks would be counted twice.
    static func footprint(at root: URL, files: [String: FileStamp]) -> (unique: [String: Int64], shared: Int64) {
        var unique: [String: Int64] = [:]
        var ranges: [(start: Int64, end: Int64)] = []
        var sharedPrivate: Int64 = 0
        var unmapped: Int64 = 0
        for (name, stamp) in files {
            let path = root.appendingPathComponent(name).path
            let own = min(privateSize(path) ?? stamp.allocated, stamp.allocated)
            unique[name] = own
            guard own < stamp.allocated else { continue }
            if let extents = physicalExtents(path) {
                ranges += extents
                sharedPrivate += own
            } else { unmapped += stamp.allocated - own }
        }
        ranges.sort { $0.start < $1.start }
        var union: Int64 = 0
        var end = Int64.min
        for range in ranges where range.end > end {
            union += range.end - max(range.start, end)
            end = range.end
        }
        return (unique, max(0, union - sharedPrivate) + unmapped)
    }

    /// APFS's count of the blocks no clone of this file shares; nil on volumes without it.
    private static func privateSize(_ path: String) -> Int64? {
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
            commonattr: attrgroup_t(ATTR_CMN_RETURNED_ATTRS), volattr: 0, dirattr: 0, fileattr: 0,
            forkattr: attrgroup_t(ATTR_CMNEXT_PRIVATESIZE))
        var buffer = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &request, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0 else { return nil }
        return buffer.withUnsafeBytes { bytes in
            let returned = bytes.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return Int64(bytes.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: UInt64.self))
        }
    }

    /// Device ranges holding the file's data, skipping holes in sparse disks.
    private static func physicalExtents(_ path: String) -> [(start: Int64, end: Int64)]? {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        var extents: [(start: Int64, end: Int64)] = []
        var offset: Int64 = 0
        while offset < info.st_size {
            let data = lseek(descriptor, offset, SEEK_DATA)
            if data < 0 { break }
            let hole = lseek(descriptor, data, SEEK_HOLE)
            guard hole > data else { return nil }
            var position = data
            while position < hole {
                var mapping = log2phys(l2p_flags: 0, l2p_contigbytes: hole - position, l2p_devoffset: position)
                guard fcntl(descriptor, F_LOG2PHYS_EXT, &mapping) == 0, mapping.l2p_contigbytes > 0 else { return nil }
                extents.append((mapping.l2p_devoffset, mapping.l2p_devoffset + mapping.l2p_contigbytes))
                position += mapping.l2p_contigbytes
            }
            offset = hole
        }
        return extents
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
        let footprint = footprint(at: library.root, files: allFiles)
        func bytes(under prefixes: [String]) -> Int64 {
            footprint.unique.filter { name, _ in prefixes.contains { name.hasPrefix($0) } }.values.reduce(0, +)
        }
        let cacheBytes = bytes(under: ["Runtime/Images/", "Runtime/Restore Images/", "Runtime/Linux Images/"])
        let capacity = try library.root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let filesystem = try FileManager.default.attributesOfFileSystem(forPath: library.root.path)
        guard let freeBytes = capacity.volumeAvailableCapacity.map(Int64.init)
            ?? (filesystem[.systemFreeSize] as? NSNumber)?.int64Value else {
            throw ComputerError("Could not determine available disk space.")
        }
        return StorageReport(freeBytes: freeBytes,
            cacheBytes: cacheBytes,
            runtimeBytes: bytes(under: ["Runtime/"]) - cacheBytes,
            computerBytes: bytes(under: ["Computers/", "Staging/"]),
            sharedBytes: footprint.shared,
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
