import Foundation

/// Writes a folder as a disk image: an MBR with one FAT32 partition, which UEFI firmware boots from and Windows
/// gives a drive letter. The sandbox rules out the system's disk tools, so the format is written here.
/// Files and folders are laid out in contiguous clusters with long names; FAT32 holds files under 4 GB.
public enum FATImage {
    public static let maximumFileSize: Int64 = 0xFFFF_FFFF

    private static let sectorSize = 512
    private static let sectorsPerCluster = 8
    private static let clusterSize = sectorSize * sectorsPerCluster
    private static let reservedSectors = 32
    private static let partitionStart = 2048
    private static let minimumClusters = 65_600

    /// `progress` gets the bytes of file data written so far and the total.
    public static func write(directory: URL, to image: URL, label: String,
                             progress: ((Int64, Int64) -> Void)? = nil) throws {
        let root = try Node(url: directory, name: "", directory: true, size: 0)
        try scan(root)
        var next = 2
        func allocate(_ node: Node) {
            node.clusters = node.directory ? max(1, (entryCount(node, root: node === root) * 32 + clusterSize - 1) / clusterSize)
                : Int((node.size + Int64(clusterSize) - 1) / Int64(clusterSize))
            if node.clusters > 0 { node.firstCluster = next; next += node.clusters }
            for child in node.children { allocate(child) }
        }
        allocate(root)
        let used = next - 2
        let clusters = max(minimumClusters, used + max(1024, used / 50))
        let fatSectors = ((clusters + 2) * 4 + sectorSize - 1) / sectorSize
        let volumeSectors = reservedSectors + 2 * fatSectors + clusters * sectorsPerCluster
        let base = Int64(partitionStart * sectorSize)
        let dataStart = base + Int64((reservedSectors + 2 * fatSectors) * sectorSize)
        func offset(_ cluster: Int) -> Int64 { dataStart + Int64(cluster - 2) * Int64(clusterSize) }

        guard FileManager.default.createFile(atPath: image.path, contents: nil) else {
            throw ComputerError("Cannot create the install disk image.")
        }
        let file = try FileHandle(forWritingTo: image)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(partitionStart + volumeSectors) * UInt64(sectorSize))
        func put(_ data: Data, at position: Int64) throws {
            try file.seek(toOffset: UInt64(position))
            try file.write(contentsOf: data)
        }

        try put(masterBootRecord(volumeSectors: volumeSectors), at: 0)
        let boot = bootSector(volumeSectors: volumeSectors, fatSectors: fatSectors, label: label)
        let info = fsInfo(free: clusters - used, next: next)
        for copy in [0, 6] {
            try put(boot, at: base + Int64(copy * sectorSize))
            try put(info, at: base + Int64((copy + 1) * sectorSize))
        }

        var table = [UInt32](repeating: 0, count: clusters + 2)
        table[0] = 0x0FFF_FFF8
        table[1] = 0x0FFF_FFFF
        func chain(_ node: Node) {
            if node.clusters > 0 {
                for cluster in node.firstCluster..<(node.firstCluster + node.clusters - 1) { table[cluster] = UInt32(cluster + 1) }
                table[node.firstCluster + node.clusters - 1] = 0x0FFF_FFFF
            }
            for child in node.children { chain(child) }
        }
        chain(root)
        let fat = table.withUnsafeBufferPointer { buffer in Data(buffer: buffer) }
        for copy in 0..<2 { try put(fat, at: base + Int64((reservedSectors + copy * fatSectors) * sectorSize)) }

        let stamp = DOSTime(Date())
        let total = root.totalSize
        var written: Int64 = 0
        var buffer = Data()
        func emit(_ node: Node, parent: Node?) throws {
            if node.directory {
                var entries = Data()
                if node === root {
                    entries.append(entry(name: shortBytes(label), attributes: 0x08, cluster: 0, size: 0, stamp: stamp))
                } else {
                    entries.append(entry(name: Array(".          ".utf8), attributes: 0x10, cluster: node.firstCluster, size: 0, stamp: stamp))
                    let up = parent === root ? 0 : parent?.firstCluster ?? 0
                    entries.append(entry(name: Array("..         ".utf8), attributes: 0x10, cluster: up, size: 0, stamp: stamp))
                }
                for child in node.children {
                    if child.longName {
                        entries.append(longEntries(child.name, checksum: checksum(child.shortName)))
                    }
                    entries.append(entry(name: child.shortName, attributes: child.directory ? 0x10 : 0x20,
                                         cluster: child.firstCluster, size: child.directory ? 0 : UInt32(child.size), stamp: stamp))
                }
                entries.append(Data(count: node.clusters * clusterSize - entries.count))
                try put(entries, at: offset(node.firstCluster))
                for child in node.children { try emit(child, parent: node) }
            } else if node.size > 0 {
                let source = try FileHandle(forReadingFrom: node.url)
                defer { try? source.close() }
                try file.seek(toOffset: UInt64(offset(node.firstCluster)))
                var remaining = node.size
                while remaining > 0 {
                    buffer = try source.read(upToCount: Int(min(remaining, 8 << 20))) ?? Data()
                    guard !buffer.isEmpty else { throw ComputerError("\(node.name) changed while the install disk was written.") }
                    try file.write(contentsOf: buffer)
                    remaining -= Int64(buffer.count)
                    written += Int64(buffer.count)
                    progress?(written, total)
                }
            }
        }
        try emit(root, parent: nil)
        progress?(written, total)
    }

    private final class Node {
        let url: URL, name: String, directory: Bool, size: Int64
        var children: [Node] = []
        var shortName: [UInt8] = []
        var longName = false
        var firstCluster = 0, clusters = 0
        init(url: URL, name: String, directory: Bool, size: Int64) throws {
            guard size <= FATImage.maximumFileSize else {
                throw ComputerError("\(name) is too large for the install disk (FAT32 holds files under 4 GB).")
            }
            self.url = url; self.name = name; self.directory = directory; self.size = size
        }
        var totalSize: Int64 { directory ? children.reduce(0) { $0 + $1.totalSize } : size }
    }

    private static func scan(_ node: Node) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var used = Set<[UInt8]>()
        node.children = try FileManager.default.contentsOfDirectory(at: node.url, includingPropertiesForKeys: keys)
            .filter { !$0.lastPathComponent.hasPrefix("._") && $0.lastPathComponent != ".DS_Store" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true else { return nil }
                let name = url.lastPathComponent
                guard name.utf16.count <= 255 else { throw ComputerError("\(name) is too long a name for the install disk.") }
                let child = try Node(url: url, name: name, directory: values.isDirectory == true, size: Int64(values.fileSize ?? 0))
                (child.shortName, child.longName) = shortName(for: name, used: &used)
                if child.directory { try scan(child) }
                return child
            }
    }

    private static func entryCount(_ node: Node, root: Bool) -> Int {
        node.children.reduce(root ? 1 : 2) { $0 + 1 + ($1.longName ? ($1.name.utf16.count + 12) / 13 : 0) }
    }

    // MARK: Names

    private static let shortCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789$%'-_@~`!(){}^#&")

    /// The 8.3 name, and whether the name needs long-name entries as well.
    private static func shortName(for name: String, used: inout Set<[UInt8]>) -> ([UInt8], Bool) {
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let base = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[name.index(after: $0)...]) } ?? ""
        func clean(_ text: String) -> String {
            String(text.uppercased().compactMap { $0 == " " || $0 == "." ? nil : shortCharacters.contains($0) ? $0 : "_" })
        }
        let cleanBase = clean(base), cleanExt = clean(ext)
        let exact = name == name.uppercased() && cleanBase == base && cleanExt == ext
            && (1...8).contains(base.count) && ext.count <= 3
        if exact {
            let bytes = shortBytes(base, ext)
            if used.insert(bytes).inserted { return (bytes, false) }
        }
        let stem = cleanBase.isEmpty ? "_" : cleanBase
        for number in 1... {
            let tail = "~\(number)"
            let bytes = shortBytes(String(stem.prefix(min(6, 8 - tail.count))) + tail, String(cleanExt.prefix(3)))
            if used.insert(bytes).inserted { return (bytes, true) }
        }
        fatalError("unreachable")
    }

    private static func shortBytes(_ base: String, _ ext: String = "") -> [UInt8] {
        let pad = { (text: String, count: Int) in Array(text.utf8.prefix(count)) + Array(repeating: 0x20, count: max(0, count - text.utf8.count)) }
        return pad(base, 8) + pad(ext, 3)
    }

    private static func checksum(_ short: [UInt8]) -> UInt8 {
        short.reduce(UInt8(0)) { (($0 & 1) << 7) &+ ($0 >> 1) &+ $1 }
    }

    private static func longEntries(_ name: String, checksum: UInt8) -> Data {
        var units = Array(name.utf16)
        if units.count % 13 != 0 { units.append(0) }
        while units.count % 13 != 0 { units.append(0xFFFF) }
        let count = units.count / 13
        var data = Data()
        for index in stride(from: count, through: 1, by: -1) {
            let part = units[((index - 1) * 13)..<(index * 13)]
            var entry = [UInt8](repeating: 0, count: 32)
            entry[0] = UInt8(index) | (index == count ? 0x40 : 0)
            entry[11] = 0x0F
            entry[13] = checksum
            for (slot, unit) in zip([1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30], part) {
                entry[slot] = UInt8(unit & 0xFF); entry[slot + 1] = UInt8(unit >> 8)
            }
            data.append(contentsOf: entry)
        }
        return data
    }

    // MARK: Structures

    private struct DOSTime {
        let date: UInt16, time: UInt16
        init(_ moment: Date) {
            let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: moment)
            date = UInt16(max(0, (parts.year ?? 1980) - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
            time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        }
    }

    private static func entry(name: [UInt8], attributes: UInt8, cluster: Int, size: UInt32, stamp: DOSTime) -> Data {
        var entry = [UInt8](repeating: 0, count: 32)
        entry.replaceSubrange(0..<11, with: name)
        entry[11] = attributes
        func put16(_ value: UInt16, _ at: Int) { entry[at] = UInt8(value & 0xFF); entry[at + 1] = UInt8(value >> 8) }
        put16(stamp.time, 14); put16(stamp.date, 16); put16(stamp.date, 18)
        put16(UInt16(cluster >> 16), 20)
        put16(stamp.time, 22); put16(stamp.date, 24)
        put16(UInt16(cluster & 0xFFFF), 26)
        put16(UInt16(size & 0xFFFF), 28); put16(UInt16(size >> 16), 30)
        return Data(entry)
    }

    private static func little(_ value: UInt32, into sector: inout [UInt8], at offset: Int) {
        for index in 0..<4 { sector[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF) }
    }

    private static func masterBootRecord(volumeSectors: Int) -> Data {
        var sector = [UInt8](repeating: 0, count: sectorSize)
        // Windows keeps a disk without a signature offline, giving it no drive letter, when it cannot write one.
        little(UInt32.random(in: 1...UInt32.max), into: &sector, at: 440)
        // One partition, FAT32 with LBA addressing; CHS values say "use LBA".
        sector.replaceSubrange(446..<454, with: [0x00, 0xFE, 0xFF, 0xFF, 0x0C, 0xFE, 0xFF, 0xFF])
        little(UInt32(partitionStart), into: &sector, at: 454)
        little(UInt32(volumeSectors), into: &sector, at: 458)
        sector[510] = 0x55; sector[511] = 0xAA
        return Data(sector)
    }

    private static func bootSector(volumeSectors: Int, fatSectors: Int, label: String) -> Data {
        var sector = [UInt8](repeating: 0, count: sectorSize)
        sector.replaceSubrange(0..<11, with: [0xEB, 0x58, 0x90] + Array("MSWIN4.1".utf8))
        sector[11] = 0x00; sector[12] = 0x02                    // bytes per sector
        sector[13] = UInt8(sectorsPerCluster)
        sector[14] = UInt8(reservedSectors); sector[15] = 0
        sector[16] = 2                                         // FATs
        sector[21] = 0xF8                                      // fixed disk
        sector[24] = 63; sector[26] = 255                      // sectors per track, heads
        little(UInt32(partitionStart), into: &sector, at: 28)  // hidden sectors
        little(UInt32(volumeSectors), into: &sector, at: 32)
        little(UInt32(fatSectors), into: &sector, at: 36)
        little(2, into: &sector, at: 44)                       // root directory cluster
        sector[48] = 1                                         // FSInfo sector
        sector[50] = 6                                         // backup boot sector
        sector[64] = 0x80                                      // drive number
        sector[66] = 0x29                                      // extended boot signature
        little(UInt32.random(in: 1...UInt32.max), into: &sector, at: 67)
        sector.replaceSubrange(71..<82, with: shortBytes(label))
        sector.replaceSubrange(82..<90, with: Array("FAT32   ".utf8))
        sector[510] = 0x55; sector[511] = 0xAA
        return Data(sector)
    }

    private static func fsInfo(free: Int, next: Int) -> Data {
        var sector = [UInt8](repeating: 0, count: sectorSize)
        little(0x4161_5252, into: &sector, at: 0)
        little(0x6141_7272, into: &sector, at: 484)
        little(UInt32(free), into: &sector, at: 488)
        little(UInt32(next), into: &sector, at: 492)
        little(0xAA55_0000, into: &sector, at: 508)
        return Data(sector)
    }
}
