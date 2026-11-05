// Adapted from ChatBotKit Studio's StorageMaintenance.swift.
// Copyright 2026 CBK.AI LTD. Licensed under Apache-2.0.
import ComputerCore
import Containerization
import ContainerizationOCI
import Foundation

public struct StorageReport: Sendable {
    public let freeBytes: Int64
    public let cacheBytes: Int64
    public let runtimeBytes: Int64
    public let computerBytes: Int64
    public let sharedBytes: Int64
    /// Everything Free Up Space returns: unused images and installers, copies kept from
    /// before image updates, and free space inside computer disks.
    public let reclaimableBytes: Int64
    /// The part of `reclaimableBytes` inside each computer's own folder.
    let computerReclaimableBytes: [UUID: Int64]
    let obsoleteImages: [String]
    let obsoleteFiles: [String]
    let recoveryCopies: [StorageMaintenance.RecoveryCopy]
    let runtimeSnapshot: [String: StorageMaintenance.FileStamp]
    let protectedImages: Set<String>?

    public var canClean: Bool { reclaimableBytes > 0 }

    /// What cleaning frees while leaving these computers' disks alone.
    public func reclaimableBytes(skipping computers: Set<UUID>) -> Int64 {
        reclaimableBytes - computers.compactMap { computerReclaimableBytes[$0] }.reduce(0, +)
    }
}

enum StorageMaintenance {
    struct FileStamp: Equatable, Sendable {
        let bytes: Int64
        let allocated: Int64
        let modified: Date?
        let inode: UInt64
    }

    /// The base/overlay pair an image update replaced. Nothing restores it, and its
    /// overlay stops sharing blocks with the active copy as the computer writes.
    struct RecoveryCopy: Equatable, Sendable {
        let computer: UUID
        let generation: UUID
        let active: UUID
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

    /// Images still needed once cleanup has removed the recovery copies, so their images go too.
    static func protectedImages(library: ComputerLibrary) throws -> Set<String>? {
        var keep = try Set([ContainerComputer.initReference, Computer.shellImage].map(normalized))
        for computer in try library.load() where computer.kind == .container {
            keep.insert(try normalized(computer.imageReference))
            // Missing/corrupt disk metadata means we cannot prove an image unused.
            guard let state = try? ContainerDiskState.load(in: library.directory(for: computer.id)) else { return nil }
            keep.insert(state.imageDigest)
        }
        return keep
    }

    /// Each container computer's active writable disk and its recovery copy, if any.
    static func containerDisks(library: ComputerLibrary) throws -> [(computer: UUID, upper: String, recovery: RecoveryCopy?)] {
        try library.load().filter { $0.kind == .container }.compactMap { computer in
            let directory = library.directory(for: computer.id)
            guard let state = try? ContainerDiskState.load(in: directory) else { return nil }
            let prefix = "Computers/\(computer.id.uuidString.lowercased())/Layers/"
            let upper = prefix + state.generation.uuidString.lowercased() + "/Upper.ext4"
            guard let previous = state.previousGeneration, previous != state.generation,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent("Layers/\(previous.uuidString.lowercased())").path)
            else { return (computer.id, upper, nil) }
            return (computer.id, upper, RecoveryCopy(computer: computer.id, generation: previous, active: state.generation))
        }
    }

    /// Repoints the computer at its active pair alone, then deletes the replaced pair, so an
    /// interruption never leaves the metadata naming a missing generation.
    static func removeRecoveryCopy(_ copy: RecoveryCopy, library: ComputerLibrary) throws {
        let directory = library.directory(for: copy.computer)
        let state = try ContainerDiskState.load(in: directory)
        guard state.generation == copy.active, state.previousGeneration == copy.generation else {
            throw ComputerError("A computer's disk changed since the preview. Refresh Storage and try again.")
        }
        try ContainerDiskState(generation: state.generation, imageReference: state.imageReference,
                               imageDigest: state.imageDigest).activate(in: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Layers/\(copy.generation.uuidString.lowercased())"))
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
        var referenced: Set<String>?
        if FileManager.default.fileExists(atPath: imagePath.path) {
            let images = try ImageStore(path: imagePath)
            if let keep {
                var kept = Set<String>()
                for image in try await images.list() {
                    if keep.contains(try normalized(image.reference)) || keep.contains(image.digest) {
                        for digest in try await image.referencedDigests() {
                            kept.insert(digest.split(separator: ":").last.map(String.init) ?? digest)
                        }
                    } else { obsolete.append(image.reference) }
                }
                obsolete.sort()
                referenced = kept
            }
        }
        // ImageStore can initialize bookkeeping. Capture the preview after opening it.
        let files = try snapshot(at: runtime)
        let footprint = footprint(at: library.root, files: allFiles)
        func bytes(under prefixes: [String]) -> Int64 {
            footprint.unique.filter { name, _ in prefixes.contains { name.hasPrefix($0) } }.values.reduce(0, +)
        }
        let cacheBytes = bytes(under: ["Runtime/Images/", "Runtime/Restore Images/", "Runtime/Linux Images/"])
        let obsoleteFiles = removableFiles(in: files)
        // Blob garbage collection removes every blob the kept images do not reference.
        let blobs = "Runtime/Images/content/blobs/sha256/"
        let imageBytes = referenced.map { kept in
            footprint.unique.filter { name, _ in name.hasPrefix(blobs) && !kept.contains(String(name.dropFirst(blobs.count))) }
                .values.reduce(0, +)
        } ?? 0
        let disks = try containerDisks(library: library)
        let recoveryCopies = disks.compactMap(\.recovery)
        var perComputer: [UUID: Int64] = [:]
        for disk in disks {
            let recovery = disk.recovery.map { copy in
                bytes(under: ["Computers/\(copy.computer.uuidString.lowercased())/Layers/\(copy.generation.uuidString.lowercased())/"])
            } ?? 0
            // Running computers' disks read as unclean; estimate from their current bitmaps.
            let compact = (try? DiskCompaction.reclaimableBytes(at: library.root.appendingPathComponent(disk.upper), estimate: true)) ?? 0
            if recovery + compact > 0 { perComputer[disk.computer] = recovery + compact }
        }
        let reclaimable = obsoleteFiles.compactMap { footprint.unique["Runtime/" + $0] }.reduce(0, +)
            + imageBytes + perComputer.values.reduce(0, +)
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
            sharedBytes: footprint.shared, reclaimableBytes: reclaimable, computerReclaimableBytes: perComputer,
            obsoleteImages: obsolete, obsoleteFiles: obsoleteFiles,
            recoveryCopies: recoveryCopies,
            runtimeSnapshot: files, protectedImages: keep)
    }

    /// Leaves the disks of `skipping` alone; every other computer must be stopped.
    static func clean(library: ComputerLibrary, preview: StorageReport, skipping: Set<UUID> = [],
                      progress: @escaping @Sendable (String, Double) async -> Void = { _, _ in }) async throws -> String {
        let current = try await inspect(library: library)
        guard current.runtimeSnapshot == preview.runtimeSnapshot,
              current.protectedImages == preview.protectedImages,
              current.obsoleteImages == preview.obsoleteImages,
              current.obsoleteFiles == preview.obsoleteFiles,
              current.recoveryCopies == preview.recoveryCopies else {
            throw ComputerError("Storage changed since the preview. Refresh Storage and try again.")
        }
        try Task.checkCancellation()
        let names = Dictionary(try library.load().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let copies = current.recoveryCopies.filter { !skipping.contains($0.computer) }
        let disks = try containerDisks(library: library).filter { !skipping.contains($0.computer) }
        let steps = Double(copies.count + disks.count + 1)
        var done = 0.0
        var problems: [String] = []
        for copy in copies {
            await progress("Removing the old disk copy of \(names[copy.computer] ?? "a computer")…", done / steps)
            do { try removeRecoveryCopy(copy, library: library) }
            catch { problems.append(error.localizedDescription) }
            done += 1
        }
        // After the copies are gone: these disks no longer share blocks with them.
        for disk in disks {
            try Task.checkCancellation()
            await progress("Compacting \(names[disk.computer] ?? "a computer")’s disk…", done / steps)
            do { try DiskCompaction.compact(at: library.root.appendingPathComponent(disk.upper)) }
            catch { problems.append(error.localizedDescription) }
            done += 1
        }
        await progress("Removing unused downloads…", done / steps)
        let runtime = library.root.appendingPathComponent("Runtime")
        let imagePath = runtime.appendingPathComponent("Images")
        if current.protectedImages != nil, FileManager.default.fileExists(atPath: imagePath.path) {
            let images = try ImageStore(path: imagePath)
            for reference in current.obsoleteImages {
                try await images.delete(reference: reference, performCleanup: false)
            }
            try await images.cleanUpOrphanedBlobs()
        }
        for name in current.obsoleteFiles {
            try FileManager.default.removeItem(at: runtime.appendingPathComponent(name))
        }
        let after = try library.root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity.map(Int64.init)
        let freed = after.map { ByteCountFormatter.string(fromByteCount: max(0, $0 - current.freeBytes), countStyle: .file) }
        return ([freed.map { "Freed \($0)." } ?? "Freed unused space.",
                 "Your computers’ files were kept. Removed downloads are fetched again when needed."] + problems)
            .joined(separator: "\n")
    }
}
