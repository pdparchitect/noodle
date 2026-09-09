import CryptoKit
import Foundation

/// Completed restore images only. Partial downloads never become cache entries.
public struct RestoreImageCache: Sendable {
    private struct Record: Codable {
        let source: URL
        let size: Int64
        let sha256: String
    }
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func imageURL(for source: URL) -> URL {
        let key = SHA256.hash(data: Data(source.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key).appendingPathExtension(source.pathExtension == "iso" ? "iso" : "ipsw")
    }

    public func verifiedImage(for source: URL, expectedSHA256: String? = nil) throws -> URL? {
        let image = imageURL(for: source)
        guard let data = try? Data(contentsOf: image.appendingPathExtension("json")),
            let record = try? JSONDecoder().decode(Record.self, from: data), record.source == source,
            let size = try? Self.fileSize(image), size == record.size
        else { return nil }
        guard expectedSHA256 == nil || record.sha256 == expectedSHA256,
              try Self.hash(image) == record.sha256 else { return nil }
        return image
    }

    /// Consumes an already completed download; retains it across cancelled installs.
    public func store(download: URL, source: URL, expectedSHA256: String? = nil) throws -> URL {
        let hash = try Self.hash(download)
        guard expectedSHA256 == nil || hash == expectedSHA256 else {
            throw ComputerError("The downloaded installer failed its checksum check. Please try again.")
        }
        let size = try Self.fileSize(download)
        guard size > 0 else {
            throw ComputerError("The restore image is empty.")
        }
        try Task.checkCancellation()
        let image = imageURL(for: source)
        if FileManager.default.fileExists(atPath: image.path) {
            _ = try FileManager.default.replaceItemAt(image, withItemAt: download)
        } else {
            try FileManager.default.moveItem(at: download, to: image)
        }
        let record = Record(source: source, size: size, sha256: hash)
        try JSONEncoder().encode(record).write(to: image.appendingPathExtension("json"), options: .atomic)
        return image
    }

    private static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 4 * 1_048_576), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(_ file: URL) throws -> Int64 {
        // URL.resourceValues can retain stale size metadata after replacement.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber else { throw ComputerError("Cannot read restore image size.") }
        return size.int64Value
    }
}
