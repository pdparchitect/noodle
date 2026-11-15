import Foundation
import Observation

/// How much disk the app's own data takes, measured on demand rather than recorded over time.
public struct StorageSnapshot: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case bots = "Bots", conversations = "Conversations", harnesses = "Harnesses", logins = "Logins",
             usage = "Usage Records", hubs = "Hubs", caches = "Caches", other = "Other"
    }

    public let kinds: [Kind: Int64]
    /// Each bot's own folder, by bot ID; together they make up `kinds[.bots]`.
    public let bots: [UUID: Int64]
    public let date: Date

    public init(kinds: [Kind: Int64], bots: [UUID: Int64], date: Date) {
        self.kinds = kinds
        self.bots = bots
        self.date = date
    }

    public var total: Int64 { kinds.values.reduce(0, +) }

    /// Walks the data folder and the container folders beside it; slow for large folders, so never on the main thread.
    public static func measure(dataRoot: URL, applicationSupport: URL, library: URL, now: Date = Date()) -> StorageSnapshot {
        let manager = FileManager.default
        var kinds: [Kind: Int64] = [:]
        var bots: [UUID: Int64] = [:]
        let entries = (try? manager.contentsOfDirectory(at: dataRoot, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            if name == "Agents" {
                for folder in (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [] {
                    let bytes = size(of: folder)
                    kinds[.bots, default: 0] += bytes
                    if let id = UUID(uuidString: folder.lastPathComponent) { bots[id, default: 0] += bytes }
                }
                continue
            }
            let kind: Kind = switch name {
            case "Conversations": .conversations
            case "Harnesses": .harnesses
            // Each login's own home: its credentials and whatever its harness keeps beside them, such as plugins.
            case "HarnessProfiles", "HarnessLogins": .logins
            case "Hubs": .hubs
            case _ where name.hasPrefix("usage.sqlite"): .usage
            default: .other
            }
            kinds[kind, default: 0] += size(of: entry)
        }
        kinds[.hubs, default: 0] += size(of: applicationSupport.appendingPathComponent("This Mac Hub", isDirectory: true))
        for name in ["Caches", "WebKit", "HTTPStorages"] {
            kinds[.caches, default: 0] += size(of: library.appendingPathComponent(name, isDirectory: true))
        }
        return StorageSnapshot(kinds: kinds.filter { $0.value > 0 }, bots: bots, date: now)
    }

    /// Space allocated on disk, not following symbolic links; a missing item is zero.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        func allocated(_ url: URL) -> Int64 {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return allocated(url) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator { total += allocated(file) }
        return total
    }
}

/// The last disk measurement, kept while a fresh one runs in the background.
@MainActor
@Observable
public final class StorageUsage {
    public private(set) var snapshot: StorageSnapshot?
    public private(set) var isMeasuring = false
    @ObservationIgnored private let measure: @Sendable () -> StorageSnapshot

    public init(dataRoot: URL, applicationSupport: URL, library: URL) {
        measure = { StorageSnapshot.measure(dataRoot: dataRoot, applicationSupport: applicationSupport, library: library) }
    }

    init(measure: @escaping @Sendable () -> StorageSnapshot) {
        self.measure = measure
    }

    /// Measures again unless a measurement is already running; the previous result stays until the new one lands.
    public func refresh() {
        guard !isMeasuring else { return }
        isMeasuring = true
        let measure = measure
        Task {
            let snapshot = await Task.detached(priority: .utility) { measure() }.value
            self.snapshot = snapshot
            isMeasuring = false
        }
    }
}
