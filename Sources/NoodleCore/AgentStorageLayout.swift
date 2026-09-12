import Foundation

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
        case .codex: prefix = "codex"
        case .claudeCode: prefix = "claude"
        case .fx: prefix = "fx"
        case .grokBuild: prefix = "grok"
        case .muse: prefix = "muse"
        }
        return runtime.appendingPathComponent("\(prefix)-runtime\(extendedAccess ? "-extended" : "").json")
    }

    public func create() throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
        try markCurrent()
    }

    public func validate() throws {
        try Self.requireDirectory(package)
        let marker = package.appendingPathComponent(Self.markerName)
        guard Self.exists(marker) else {
            throw AgentStorageError("This bot needs a storage migration. Run Noodle 0.13.0 to upgrade its older workspace before starting it.")
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
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
