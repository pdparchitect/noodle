import Compression
import Foundation

/// A noodlet's files as one compressed file, as a Hub sends it to a device: a header, then each
/// file's name and bytes in turn, all compressed with LZFSE as one stream.
public enum NoodletArchive {
    static let magic = Data("NOODLET1".utf8)
    private static let piece = 1_048_576

    /// Archives `names`, relative to `root`, into a new file at `destination`. `root` is resolved
    /// already, as `NoodletPath.open` takes it.
    public static func write(_ names: [String], from root: URL, to destination: URL) throws {
        try write(to: destination) { add in
            for name in names {
                let handle = try NoodletPath.open(name, in: root)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                try handle.seek(toOffset: 0)
                try add(name, size) { try handle.read(upToCount: piece) ?? Data() }
            }
        }
    }

    /// Archives files given in memory, for tests.
    static func write(entries: [(String, Data)], to destination: URL) throws {
        try write(to: destination) { add in
            for (name, data) in entries {
                var sent = false
                try add(name, UInt64(data.count)) { defer { sent = true }; return sent ? Data() : data }
            }
        }
    }

    private typealias Add = (String, UInt64, () throws -> Data) throws -> Void

    private static func write(to destination: URL, _ files: (Add) throws -> Void) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let filter = try OutputFilter(.compress, using: .lzfse) { data in
            if let data { try output.write(contentsOf: data) }
        }
        try filter.write(magic)
        try files { name, size, read in
            let bytes = Data(name.utf8)
            try filter.write(number(UInt32(bytes.count)) + bytes + number(size))
            var left = size
            while left > 0 {
                let data = try read()
                guard !data.isEmpty, UInt64(data.count) <= left else { throw AppletError("\(name) changed while it was being sent.") }
                try filter.write(data)
                left -= UInt64(data.count)
            }
        }
        try filter.write(number(UInt32(0)))
        try filter.finalize()
    }

    /// Unpacks an archive into a new folder at `destination`, replacing whatever is there once
    /// every file has come out.
    public static func extract(_ archive: URL, to destination: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let filter = try InputFilter(.decompress, using: .lzfse) { count in try input.read(upToCount: count) }
        func read(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let more = try filter.readData(ofLength: count - data.count), !more.isEmpty else {
                    throw AppletError("The noodlet arrived incomplete.")
                }
                data.append(more)
            }
            return data
        }
        guard (try? read(magic.count)) == magic else { throw AppletError("This is not a noodlet sent from a Hub.") }
        while true {
            let length = Int(try read(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            if length == 0 { break }
            guard length < 2048, let name = String(data: try read(length), encoding: .utf8) else {
                throw AppletError("The noodlet arrived damaged.")
            }
            let file = try NoodletPath.child(name, in: stage)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: file.path, contents: nil)
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            var left = try read(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            while left > 0 {
                let data = try read(Int(min(left, UInt64(piece))))
                try output.write(contentsOf: data)
                left -= UInt64(data.count)
            }
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: stage)
        } else {
            try fm.moveItem(at: stage, to: destination)
        }
    }

    private static func number<N: FixedWidthInteger>(_ value: N) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
