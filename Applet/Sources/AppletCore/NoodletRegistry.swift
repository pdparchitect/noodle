import Foundation

/// Link identity is independent of a running session and never written into authored packages.
public final class NoodletRegistry {
    private struct Entry: Codable {
        var id: UUID
        var path: String
        var bookmark: Data
    }
    private let file: URL
    private var entries: [Entry]

    public init(file: URL) throws {
        self.file = file
        entries = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file)) : []
    }

    public func id(for package: URL) throws -> UUID {
        let url = package.resolvingSymlinksInPath().standardizedFileURL
        let index = entries.firstIndex { entry in
            entry.path == url.path || resolved(entry) == url
        }
        if let index, entries[index].path == url.path { return entries[index].id }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let entry = Entry(id: index.map { entries[$0].id } ?? UUID(), path: url.path, bookmark: bookmark)
        let previous = entries
        if let index { entries[index] = entry } else { entries.append(entry) }
        do { try persist() } catch { entries = previous; throw error }
        return entry.id
    }

    public func resolve(_ id: UUID) -> URL? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        return resolved(entry)
    }

    private func resolved(_ entry: Entry) -> URL? {
        var stale = false
        let bookmarked = try? URL(resolvingBookmarkData: entry.bookmark,
            options: [.withoutUI], bookmarkDataIsStale: &stale)
        for candidate in [bookmarked, URL(fileURLWithPath: entry.path)].compactMap({ $0 }) {
            let url = candidate.resolvingSymlinksInPath().standardizedFileURL
            if !url.pathComponents.contains(".Trash"), !url.pathComponents.contains(".Trashes"),
               (try? url.checkResourceIsReachable()) == true { return url }
        }
        return nil
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
