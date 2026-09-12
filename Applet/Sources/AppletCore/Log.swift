import Foundation

public final class AppletLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    public init(url: URL) { self.url = url }
    public func append(_ channel: String, _ text: String) { append(text, channel: channel) }
    public func append(_ text: String, channel: String = "runtime") {
        lock.lock()
        defer { lock.unlock() }
        let row: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()), "channel": channel,
            "text": String(decoding: text.utf8.prefix(16384), as: UTF8.self),
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        else { return }
        data.append(10)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        // Stop growing after 32 MiB; preserve all earlier byte cursors.
        if let end = try? handle.seekToEnd(), end < 32 * 1_048_576 {
            try? handle.write(contentsOf: data)
        }
    }
    public func read(offset: Int, limit: Int = 256 * 1024) throws -> (Data, Int) {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return (Data(), 0) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        var data = try handle.read(upToCount: limit) ?? Data()
        if data.count == limit, let newline = data.lastIndex(of: 10) {
            data = Data(data[...newline])
        }
        return (data, offset + data.count)
    }
}
