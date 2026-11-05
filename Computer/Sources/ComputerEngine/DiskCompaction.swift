import ComputerCore
import Foundation

/// Returns space a stopped computer's sparse ext4 disk no longer uses to the Mac. Guests
/// delete files without discarding their blocks, so without this the disk only grows.
enum DiskCompaction {
    /// Bytes the Mac holds for blocks ext4 marks free; zero when the disk cannot be compacted.
    /// An estimate also reads a mounted disk, whose on-disk bitmaps may lag slightly.
    static func reclaimableBytes(at url: URL, estimate: Bool = false) throws -> Int64 {
        try withDisk(url, flags: O_RDONLY) { descriptor in
            guard let free = try freeRanges(descriptor, mounted: estimate) else { return 0 }
            return overlap(free, dataRanges(descriptor)).reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        }
    }

    /// Punches holes over free blocks. The computer must be stopped; returns the bytes freed.
    @discardableResult
    static func compact(at url: URL) throws -> Int64 {
        try withDisk(url, flags: O_RDWR) { descriptor in
            // Data still in the page cache can read as a hole until it is written out.
            guard fsync(descriptor) == 0 else { throw ComputerError("Could not flush \(url.lastPathComponent).") }
            guard let free = try freeRanges(descriptor, mounted: false) else { return 0 }
            var volume = statfs()
            guard fstatfs(descriptor, &volume) == 0 else { throw ComputerError("Could not inspect the volume holding \(url.lastPathComponent).") }
            // APFS punches only whole allocation blocks.
            let unit = Int64(volume.f_bsize)
            let before = allocated(descriptor)
            for range in overlap(free, dataRanges(descriptor)) {
                let start = (range.lowerBound + unit - 1) / unit * unit
                let end = range.upperBound / unit * unit
                guard end > start else { continue }
                var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
                guard fcntl(descriptor, F_PUNCHHOLE, &hole) == 0 else {
                    throw ComputerError("Could not compact \(url.lastPathComponent): \(String(cString: strerror(errno))).")
                }
            }
            return max(0, before - allocated(descriptor))
        }
    }

    private static func withDisk<T>(_ url: URL, flags: Int32, _ body: (Int32) throws -> T) throws -> T {
        let descriptor = open(url.path, flags | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ComputerError("Could not open \(url.lastPathComponent).") }
        defer { close(descriptor) }
        return try body(descriptor)
    }

    private static func allocated(_ descriptor: Int32) -> Int64 {
        var info = stat()
        return fstat(descriptor, &info) == 0 ? Int64(info.st_blocks) * 512 : 0
    }

    /// Free block ranges from the ext4 block bitmaps, or nil unless the filesystem was
    /// unmounted cleanly: a pending journal replay or recorded error could reuse them.
    /// `mounted` accepts a pending replay, for estimates only.
    static func freeRanges(_ descriptor: Int32, mounted: Bool) throws -> [Range<Int64>]? {
        func read(_ count: Int, at offset: Int64) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: count)
            let read = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
            guard read == count else { throw ComputerError("Could not read the computer's disk.") }
            return bytes
        }
        func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 { UInt32(u16(bytes, offset)) | UInt32(u16(bytes, offset + 2)) << 16 }

        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 2048 else { return nil }
        let superBlock = try read(1024, at: 1024)
        let state = u16(superBlock, 0x3A)
        let incompatible = u32(superBlock, 0x60)
        // Magic; valid without errors; no needs_recovery, external journal or meta_bg layout.
        guard u16(superBlock, 0x38) == 0xEF53, state & 0x3 == 0x1,
              incompatible & (mounted ? 0x18 : 0x1C) == 0 else { return nil }
        let logBlockSize = u32(superBlock, 0x18)
        guard logBlockSize <= 6 else { return nil }
        let blockSize = Int64(1024) << Int64(logBlockSize)
        let wide = incompatible & 0x80 != 0
        let blocks = Int64(u32(superBlock, 0x04)) | (wide ? Int64(u32(superBlock, 0x150)) << 32 : 0)
        let first = Int64(u32(superBlock, 0x14))
        let perGroup = Int64(u32(superBlock, 0x20))
        let descriptorSize = wide ? Int(u16(superBlock, 0xFE)) : 32
        guard perGroup > 0, perGroup <= blockSize * 8, blocks > first, descriptorSize >= 32 else { return nil }
        let groups = (blocks - first + perGroup - 1) / perGroup
        let table = try read(Int(groups) * descriptorSize, at: (first + 1) * blockSize)
        var ranges: [Range<Int64>] = []
        for group in 0..<groups {
            let entry = Int(group) * descriptorSize
            // BLOCK_UNINIT groups have no bitmap on disk; leave them alone.
            if u16(table, entry + 0x12) & 0x2 != 0 { continue }
            let high = wide && descriptorSize >= 64 ? Int64(u32(table, entry + 0x20)) << 32 : 0
            let bitmap = try read(Int(blockSize), at: (Int64(u32(table, entry)) | high) * blockSize)
            let start = first + group * perGroup
            let count = min(perGroup, blocks - start)
            var run: Int64?
            for index in 0...count {
                let used = index == count || bitmap[Int(index >> 3)] >> UInt8(index & 7) & 1 == 1
                if !used, run == nil { run = index }
                else if used, let begin = run {
                    ranges.append((start + begin) * blockSize ..< (start + index) * blockSize)
                    run = nil
                }
            }
        }
        return ranges
    }

    private static func dataRanges(_ descriptor: Int32) -> [Range<Int64>] {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return [] }
        var ranges: [Range<Int64>] = []
        var offset: off_t = 0
        while offset < info.st_size {
            let data = lseek(descriptor, offset, SEEK_DATA)
            guard data >= 0 else { break }
            let hole = lseek(descriptor, data, SEEK_HOLE)
            guard hole > data else { break }
            ranges.append(Int64(data)..<Int64(hole))
            offset = hole
        }
        return ranges
    }

    /// Both inputs are sorted and non-overlapping.
    static func overlap(_ a: [Range<Int64>], _ b: [Range<Int64>]) -> [Range<Int64>] {
        var result: [Range<Int64>] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let range = a[i].clamped(to: b[j])
            if !range.isEmpty { result.append(range) }
            if a[i].upperBound < b[j].upperBound { i += 1 } else { j += 1 }
        }
        return result
    }
}
