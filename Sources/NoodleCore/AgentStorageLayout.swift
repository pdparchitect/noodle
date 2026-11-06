import Foundation
import ProductIdentity

/// The copyable agent package contains app-owned configuration and state beside
/// the harness's working directory. Paths do not depend on the display name.
public struct AgentStorageLayout: Sendable {
    public static let version = 1
    public static let markerName = ".noodle-storage.json"
    public let package: URL
    public var workspace: URL { package.appendingPathComponent("workspace", isDirectory: true) }
    public var runtime: URL { package.appendingPathComponent("runtime", isDirectory: true) }
    public var configuration: URL { package.appendingPathComponent("agent.json") }

    public init(package: URL) { self.package = package.standardizedFileURL }

    public init(workspace: URL) {
        self.init(package: workspace.deletingLastPathComponent())
    }

    public func sessionState(provider: HarnessProvider, extendedAccess: Bool) -> URL {
        let prefix: String
        switch provider {
        case .apple: prefix = "apple"
        case .codex: prefix = "codex"
        case .claudeCode: prefix = "claude"
        case .fx: prefix = "fx"
        case .grokBuild: prefix = "grok"
        case .muse: prefix = "muse"
        case .openCode: prefix = "opencode"
        case .antigravity: prefix = "antigravity"
        }
        return runtime.appendingPathComponent("\(prefix)-runtime\(extendedAccess ? "-extended" : "").json")
    }

    public func create() throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
            try markCurrent()
        } catch {
            let original = error
            try FileManager.default.removeItem(at: package)
            throw original
        }
    }

    public func validate() throws {
        try Self.requireDirectory(package)
        let marker = package.appendingPathComponent(Self.markerName)
        guard Self.exists(marker) else {
            throw AgentStorageError.madeBefore("0.13.0")
        }
        try Self.requireFile(marker)
        let state = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: marker))
        guard state.version == Self.version else {
            throw AgentStorageError("This bot uses storage version \(state.version). Open a compatible version of Noodle.")
        }
        try Self.requireFile(configuration)
        try Self.requireDirectory(workspace)
        try Self.requireDirectory(runtime)
    }

    /// Makes the empty workspace or runtime folder `create` makes, when nothing else is wrong
    /// with a current package, as after a crash or a full disk cut writing a bot short.
    /// Anything else, such as an older, redirected or unreadable package, is left for
    /// `validate` and the configuration to refuse, untouched.
    func restoreMissingFolders() throws {
        let missing = [workspace, runtime].filter { !Self.exists($0) }
        let marker = package.appendingPathComponent(Self.markerName)
        guard !missing.isEmpty, (try? Self.requireDirectory(package)) != nil, (try? Self.requireFile(marker)) != nil,
              (try? JSONDecoder().decode(Marker.self, from: Data(contentsOf: marker)))?.version == Self.version,
              (try? Self.requireFile(configuration)) != nil,
              (try? AgentConfiguration.load(from: self).requireBackstory()) != nil else { return }
        for folder in missing {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
    }

    func markCurrent() throws {
        try Self.writeState(Marker(version: Self.version), to: package.appendingPathComponent(Self.markerName))
    }

    /// Resolve only the package layout, never a marker authored inside the
    /// writable workspace. Callers can walk up from a skill's directory.
    public static func containing(_ directory: URL) throws -> Self {
        var current = directory.resolvingSymlinksInPath().standardizedFileURL
        while current.path != "/" {
            let package = current.deletingLastPathComponent()
            if current.lastPathComponent == "workspace",
               UUID(uuidString: package.lastPathComponent) != nil,
               package.deletingLastPathComponent().lastPathComponent == "Agents" {
                let layout = Self(package: package)
                try layout.validate()
                return layout
            }
            current.deleteLastPathComponent()
        }
        throw WorkspaceError.invalidAgentDirectory
    }

    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// URL.resolvingSymlinksInPath leaves aliases such as /var unresolved when
    /// the final directory has not been created yet.
    static func canonicalURL(_ url: URL) -> URL {
        let url = url.standardizedFileURL
        if exists(url) || url.path == "/" { return url.resolvingSymlinksInPath() }
        return canonicalURL(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    static func requireDirectory(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory,
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw AgentStorageError("The bot storage directory is redirected: \(url.lastPathComponent).")
        }
    }

    static func requireFile(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw AgentStorageError("The bot storage file is not a regular file: \(url.lastPathComponent).")
        }
    }

    /// Publish complete migration state in one rename. Foundation's atomic write
    /// can first expose an empty destination when creating a brand-new file.
    static func writeState<T: Encodable>(_ value: T, to destination: URL) throws {
        try AtomicFile.write(JSONEncoder().encode(value), to: destination)
    }

    private struct Marker: Codable { let version: Int }
}

public struct AgentStorageError: LocalizedError {
    public let message: String
    /// Where the steps that fix it are explained, when there are any.
    public let helpURL: URL?
    public init(_ message: String, helpURL: URL? = nil) { self.message = message; self.helpURL = helpURL }
    public var errorDescription: String? { message }

    /// The user guide's steps for upgrading a bot made by an older version.
    public static let upgradeStepsURL = URL(string: "https://github.com/pdparchitect/noodle/blob/main/docs/releases.md#bots-from-older-versions")!

    /// For a bot made before `version`, an update milestone whose conversion later releases no longer
    /// carry: that release converts it, and its successors follow one update at a time.
    static func madeBefore(_ version: String) -> Self {
        Self("This bot was made by a \(ProductIdentity.current.name) version older than \(version). To upgrade it, back up your \(ProductIdentity.current.name) data, "
            + "install \(ProductIdentity.current.name) \(version) from https://github.com/pdparchitect/noodle/releases/tag/v\(version), "
            + "open it, and accept each update it offers.", helpURL: upgradeStepsURL)
    }
}
