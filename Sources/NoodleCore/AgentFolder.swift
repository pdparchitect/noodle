import Foundation

/// A user-chosen folder outside the bot's workspace. Stored privately in
/// agent.json. Agent Host rereads and revalidates the list before every
/// restricted launch; the XPC caller still cannot pass a path.
public struct AgentFolder: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var writable: Bool
    /// What the folder is for, in the user's words. Rendered beside the path
    /// in the generated AGENTS.md.
    public var description: String?
    public var id: String { path }

    public static let limit = 16
    public static let descriptionLimit = 500

    public init(path: String, writable: Bool = true, description: String? = nil) {
        self.path = path
        self.writable = writable
        self.description = description
    }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    /// Noodle's own storage must never be shared: it holds every bot's
    /// configuration, including this list, and other bots' workspaces.
    public static func protectedLocations(root: URL) -> [URL] {
        let components = root.standardizedFileURL.pathComponents
        guard let index = components.indices.dropLast().first(where: {
            $0 > 0 && components[$0 - 1] == "Library" && components[$0] == "Containers"
        }) else { return [root] }
        return [root, URL(fileURLWithPath: NSString.path(withComponents: Array(components[...(index + 1)])), isDirectory: true)]
    }

    /// Normalizes the list and rejects anything that would widen access to
    /// Noodle's storage. Order is preserved; repeated paths merge as `merged` does.
    public static func validated(_ folders: [AgentFolder], protecting protected: [URL],
                                 limit: Int? = limit) throws -> [AgentFolder] {
        var result: [AgentFolder] = []
        for folder in folders {
            guard folder.path.hasPrefix("/"), !folder.path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw AgentStorageError("A shared folder needs an absolute path without control characters.")
            }
            let path = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL.path
            guard path != "/" else { throw AgentStorageError("The whole disk cannot be shared with a bot. Choose a folder.") }
            let spellings = [path, RestrictedAgentSandbox.sandboxPath(path)]
            for location in protected {
                let locations = [location.standardizedFileURL.path, RestrictedAgentSandbox.sandboxPath(location.path)]
                guard !spellings.contains(where: { spelling in locations.contains { overlaps(spelling, $0) } }) else {
                    throw AgentStorageError("“\(path)” overlaps Noodle's own storage and cannot be shared with a bot.")
                }
            }
            // One generated list item per folder: keep the note on a single line.
            let description = (folder.description ?? "").split(whereSeparator: { $0.isNewline || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            guard description.count <= descriptionLimit else {
                throw AgentStorageError("A shared folder's description can have at most \(descriptionLimit) characters.")
            }
            result.append(AgentFolder(path: path, writable: folder.writable, description: description.isEmpty ? nil : description))
        }
        result = merged(result)
        if let limit, result.count > limit { throw AgentStorageError("At most \(limit) folders can be shared.") }
        return result
    }

    /// One entry per path, in first-seen order. Read and write wins, since the
    /// bot can write wherever any entry allows it; the first description stays.
    static func merged(_ folders: [AgentFolder]) -> [AgentFolder] {
        var result: [AgentFolder] = []
        for folder in folders {
            if let index = result.firstIndex(where: { $0.path == folder.path }) {
                result[index].writable = result[index].writable || folder.writable
                result[index].description = result[index].description ?? folder.description
            } else {
                result.append(folder)
            }
        }
        return result
    }

    /// The folders Agent Host may add to a restricted profile: the bot's own
    /// and its groups'. A bot can replace anything inside a writable folder
    /// with a link, so an entry nested inside one is never resolved
    /// separately. Missing folders, such as an ejected disk, are skipped
    /// instead of blocking the launch.
    public static func granted(workspace: URL, protecting protected: [URL]) throws -> [AgentFolder] {
        let layout = AgentStorageLayout(workspace: workspace)
        let configuration = try AgentConfiguration.load(from: layout)
        // Each list was limited when saved; together they may be longer.
        let folders = try validated(configuration.folders + configuration.groupFolders,
                                    protecting: protected + [layout.package], limit: nil)
        let resolved = folders.map { RestrictedAgentSandbox.sandboxPath($0.path).lowercased() }
        return folders.indices.filter { index in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folders[index].path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
            return !folders.indices.contains { folders[$0].writable && resolved[index].hasPrefix(resolved[$0] + "/") }
        }.map { folders[$0] }
    }

    static func instructions(_ folders: [AgentFolder], groups: [BotConversation] = []) -> String {
        let shared = merged(folders + groups.flatMap(\.sharedFolders))
        guard !shared.isEmpty else { return "" }
        let entries = shared.map { folder in
            let names = groups.filter { $0.sharedFolders.contains { $0.path == folder.path } }.map { "“\($0.displayName)”" }
            let source = names.isEmpty ? "" : ", shared by group\(names.count == 1 ? "" : "s") " + names.joined(separator: ", ")
            return "- `\(folder.path)` (\(folder.writable ? "read and write" : "read only")\(source))" + (folder.description.map { ": \($0)" } ?? "")
        }.joined(separator: "\n")
        return "\n## Shared folders\n\nThe user shared these folders outside your workspace; a note after a path is the user's description of that folder. A folder shared by a group is meant for that group's work, though you can reach it from every conversation. Reach them by absolute path; your workspace stays the working directory. In restricted mode every other location outside the workspace remains unavailable, and a folder that is missing or disconnected is not shared until the bot restarts.\n\n" + entries + "\n"
    }

    // Case-insensitive on purpose: APFS usually is, and a false match only
    // refuses a folder that differs from Noodle's storage by letter case.
    private static func overlaps(_ first: String, _ second: String) -> Bool {
        let first = first.lowercased(), second = second.lowercased()
        return first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }
}

extension BotConversation {
    /// What an active group shares with its bots.
    public var sharedFolders: [AgentFolder] { kind == .group && archivedAt == nil ? folders ?? [] : [] }

    /// The bots whose shared folders change when a group goes from `before` to
    /// `after`, nil being no group. Their sandbox is fixed at launch, so they restart.
    public static func botsWithChangedFolders(from before: BotConversation?, to after: BotConversation?) -> Set<UUID> {
        let old = before?.sharedFolders ?? [], new = after?.sharedFolders ?? []
        let oldBots = old.isEmpty ? [] : Set(before?.participantIDs ?? [])
        let newBots = new.isEmpty ? [] : Set(after?.participantIDs ?? [])
        return old == new ? oldBots.symmetricDifference(newBots) : oldBots.union(newBots)
    }
}
