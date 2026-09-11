import ComputerCore
import Foundation

enum PreviewPolicy {
    static let fileLimit: Int64 = 20 * 1024 * 1024
    static let cacheLimit: Int64 = 100 * 1024 * 1024
    static func suffix(for name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "png"
        case "jpg", "jpeg": return "jpg"
        case "pdf": return "pdf"
        case "txt", "md", "log", "json", "csv", "swift", "py", "js", "ts", "css", "sh", "yaml", "yml", "toml": return "txt"
        default: return nil
        }
    }
    static func validate(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let valid: Bool
        switch url.pathExtension {
        case "png": valid = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        case "jpg": valid = data.starts(with: [255, 216, 255])
        case "pdf": valid = data.starts(with: Data("%PDF-".utf8))
        case "txt": valid = !data.contains(0) && String(data: data, encoding: .utf8) != nil
        default: valid = false
        }
        guard valid else { throw ComputerError("This file’s contents do not match a supported preview format.") }
    }
}

/// A session cache with explicit reservations, active leases and a short TTL.
/// OS purging is optional; it is never needed to keep our disk use bounded.
actor FilePreviewCache {
    static let shared = FilePreviewCache()
    struct Lease: Sendable { let id: UUID; let url: URL; let reused: Bool }
    private struct Item {
        let url: URL
        let key: String
        let size: Int64
        var touched: Date
        var users: Int
        var ready: Bool
    }
    let root: URL
    private var items: [UUID: Item] = [:]
    private var prepared = false
    private var sweeper: Task<Void, Never>?
    init(root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Noodle File Previews", isDirectory: true)) { self.root = root }

    func acquire(key: String, size: Int64, suffix: String, name: String = "Preview") throws -> Lease {
        guard size >= 0, size <= PreviewPolicy.fileLimit, ["txt", "pdf", "png", "jpg"].contains(suffix) else { throw ComputerError("Preview unavailable.") }
        if !prepared {
            // No cache survives an app session. Clear leftovers from crashes.
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            prepared = true
            sweeper = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await self?.expire()
                }
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        expire()
        if let (id, item) = items.first(where: { $0.value.key == key && $0.value.ready && FileManager.default.fileExists(atPath: $0.value.url.path) }) {
            items[id]?.users += 1; items[id]?.touched = .now
            return Lease(id: id, url: item.url, reused: true)
        }
        while items.count >= 128 || items.values.reduce(0, { $0 + $1.size }) + size > PreviewPolicy.cacheLimit {
            guard let oldest = items.filter({ $0.value.users == 0 }).min(by: { $0.value.touched < $1.value.touched }) else {
                throw ComputerError("Preview cache is busy. Close another preview first.")
            }
            discard(oldest.key)
        }
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard Int64(free) >= size + PreviewPolicy.cacheLimit else { throw ComputerError("Preview skipped because disk space is low.") }
        let id = UUID()
        try GuestFile.validateName(name)
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let base = (name as NSString).deletingPathExtension
        let url = directory.appendingPathComponent(base.isEmpty ? "Preview" : base).appendingPathExtension(suffix)
        items[id] = Item(url: url, key: key, size: size, touched: .now, users: 1, ready: false)
        return Lease(id: id, url: url, reused: false)
    }
    func complete(_ lease: Lease) { items[lease.id]?.ready = true }
    func release(_ lease: Lease) {
        guard var item = items[lease.id] else { return }
        item.users = max(0, item.users - 1); item.touched = .now; items[lease.id] = item
        if !item.ready { discard(lease.id) }
    }
    func expire(now: Date = .now) {
        for (id, item) in items where item.users == 0 && now.timeIntervalSince(item.touched) >= 600 { discard(id) }
    }
    private func discard(_ id: UUID) {
        guard let item = items[id] else { return }
        do {
            if FileManager.default.fileExists(atPath: item.url.deletingLastPathComponent().path) { try FileManager.default.removeItem(at: item.url.deletingLastPathComponent()) }
            items[id] = nil
        } catch { /* Keep the reservation if bytes could not be removed. */ }
    }
    func clearUnused() { for (id, item) in items where item.users == 0 { discard(id) } }
    var reservedBytes: Int64 { items.values.reduce(0) { $0 + $1.size } }
    deinit { sweeper?.cancel() }
}
