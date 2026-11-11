#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Publish complete data using a temporary file in the destination directory.
/// Foundation's replacement-directory API can require writes outside a
/// restricted workspace, and may expose an empty newly created destination.
public enum AtomicFile {
    public static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".noodle-write-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        guard renameFile(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private func renameFile(_ source: String, _ destination: String) -> Int32 { rename(source, destination) }
