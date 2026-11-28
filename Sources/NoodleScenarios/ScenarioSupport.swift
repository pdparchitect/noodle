#if NOODLE_DEV_HOOKS
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// What every app's scenarios share and nothing on screen needs: their errors, the clock times they are written in, and
// finding the files they name. The apps that play scenarios, on the Mac and on Windows, link it. Development builds only.

public struct ScenarioError: LocalizedError {
    public let errorDescription: String?
    /// The scenario is sound but names media that scripts/scenario.sh has not fetched yet. A
    /// fresh checkout has none of it, so this is a scenario waiting for the script rather than a
    /// mistake in it.
    public let needsFetch: Bool
    public init(_ description: String, needsFetch: Bool = false) {
        errorDescription = description
        self.needsFetch = needsFetch
    }
}

public enum ScenarioTime {
    /// The clock a scenario opens at: `HH:mm` today, or the wall clock.
    public static func start(_ clock: String?, now: Date, calendar: Calendar = .current) throws -> Date {
        guard let clock else { return now }
        guard !clock.contains(" "), !clock.hasPrefix("-") else { throw ScenarioError("clock is a time such as \"09:41\".") }
        return try date(clock, clock: now, calendar: calendar)
    }

    /// `HH:mm` on the scenario's day, `-Nd HH:mm` on an earlier day, or `-Nm` and `-Nh` before the clock.
    public static func date(_ text: String, clock: Date, calendar: Calendar = .current) throws -> Date {
        func time(_ value: Substring, daysAgo: Int) -> Date? {
            let fields = value.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
            guard value.count == 5, fields.count == 2, (0..<24).contains(fields[0]), (0..<60).contains(fields[1]),
                  let day = calendar.date(byAdding: .day, value: -daysAgo, to: clock) else { return nil }
            return calendar.date(bySettingHour: fields[0], minute: fields[1], second: 0, of: day)
        }
        func ago(_ value: Substring, _ unit: Character) -> Int? {
            value.first == "-" && value.last == unit ? Int(value.dropFirst().dropLast()).flatMap { $0 >= 0 ? $0 : nil } : nil
        }
        let parts = text.split(separator: " ")
        if parts.count == 1 {
            if let date = time(parts[0], daysAgo: 0) { return date }
            if let minutes = ago(parts[0], "m") { return clock.addingTimeInterval(-60 * Double(minutes)) }
            if let hours = ago(parts[0], "h") { return clock.addingTimeInterval(-3600 * Double(hours)) }
        } else if parts.count == 2, let days = ago(parts[0], "d"), let date = time(parts[1], daysAgo: days) {
            return date
        }
        throw ScenarioError("\"\(text)\" is not a time: use \"HH:mm\", \"-2d HH:mm\", \"-15m\" or \"-3h\".")
    }
}

/// The parts of reading a scenario that do not draw. Each app adds what it needs to put one on screen.
public enum ScenarioSupport {
    /// Keys of `original` that did not survive decoding and encoding again. Null values are skipped, as encoding omits them.
    public static func unknownKeys(in original: Any, comparedTo encoded: Any?, path: String = "") -> [String] {
        if let original = original as? [String: Any] {
            let encoded = encoded as? [String: Any] ?? [:]
            return original.keys.sorted().flatMap { key -> [String] in
                guard !(original[key] is NSNull) else { return [] }
                let here = path.isEmpty ? key : "\(path).\(key)"
                return encoded[key] == nil ? [here] : unknownKeys(in: original[key]!, comparedTo: encoded[key], path: here)
            }
        }
        if let original = original as? [Any] {
            let encoded = encoded as? [Any] ?? []
            return original.enumerated().flatMap { index, value in
                unknownKeys(in: value, comparedTo: encoded.indices.contains(index) ? encoded[index] : nil, path: "\(path)[\(index)]")
            }
        }
        return []
    }

    /// A picture or video a scenario names: an asset in its own folder, or a web address
    /// that scripts/scenario.sh has fetched into the `.cache` beside the scenarios. The
    /// bundle has no network of its own, so nothing is ever downloaded from in here.
    /// A full path names a file scripts/scenario.sh has let the bundle read, such as a picture given to a recording.
    public static func media(_ value: String, in folder: URL) throws -> URL {
        if value.hasPrefix("/") {
            guard FileManager.default.fileExists(atPath: value) else { throw ScenarioError("Missing file: \(value)") }
            return URL(fileURLWithPath: value)
        }
        guard isRemote(value) else { return try file(value, under: folder) }
        // One cache for all of them: the name is the address, so two scenarios naming the
        // same thing share the one copy. Found by name rather than by extension, because a
        // web address need not end in one and the script works out what it is.
        let stem = cacheStem(for: value)
        let cache = folder.deletingLastPathComponent().appendingPathComponent(".cache", isDirectory: true)
        let found = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix(stem) }
        guard let found else {
            throw ScenarioError(
                "\(value) has not been fetched yet. scripts/scenario.sh downloads it beside the scenarios.",
                needsFetch: true)
        }
        return found
    }

    public static func isRemote(_ value: String) -> Bool {
        value.hasPrefix("https://") || value.hasPrefix("http://")
    }

    /// What a fetched address is called on disk, before its extension. The script names
    /// downloads the same way, so changing this strands every cache.
    public static func cacheStem(for address: String) -> String {
        String(SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// A file named by a scenario, kept inside `root` however the name is written.
    public static func file(_ path: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path) else {
            throw ScenarioError("Missing asset: \(path)")
        }
        return url
    }
}
#endif
