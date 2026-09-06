import Foundation

public enum HarnessProvider: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        }
    }

}

public struct HarnessInstallation: Identifiable, Codable, Hashable, Sendable {
    public let provider: HarnessProvider
    public let executablePath: String?

    public init(provider: HarnessProvider, executablePath: String?) {
        self.provider = provider
        self.executablePath = executablePath
    }

    public var id: String { provider.id }
    public var isAvailable: Bool { executablePath != nil }
    public var detail: String { isAvailable ? "Installed" : "Not installed" }
}

public struct HarnessEffort: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let description: String

    public init(id: String, description: String) {
        self.id = id
        self.description = description
    }

    public var displayName: String {
        switch id {
        case "xhigh": return "Extra High"
        default: return id.capitalized
        }
    }
}

public struct HarnessModel: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let supportedEfforts: [HarnessEffort]
    public let defaultEffort: String
    public let isDefault: Bool

    public init(
        id: String,
        displayName: String,
        description: String,
        supportedEfforts: [HarnessEffort],
        defaultEffort: String,
        isDefault: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
        self.isDefault = isDefault
    }
}

public struct HarnessDiscovery: Sendable {
    private let applicationsDirectory: URL
    private let executableSearchDirectories: [URL]
    private let standaloneCodexURL: URL
    #if DEBUG
    private let simulateNoHarnesses: Bool
    private var externalInstallChecks: Set<HarnessProvider> = []
    #endif

    public init(
        homeDirectory: URL = HarnessStorage.userHome,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        executableSearchDirectories: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        #if DEBUG
        simulateNoHarnesses = environment["NOODLE_SIMULATE_NO_HARNESSES"] == "1"
        #endif
        self.applicationsDirectory = applicationsDirectory.standardizedFileURL
        self.standaloneCodexURL = homeDirectory.appendingPathComponent(".codex/packages/standalone/current/bin/codex")
        self.executableSearchDirectories = executableSearchDirectories ?? [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        ]
    }

    public func discover() -> [HarnessInstallation] {
        HarnessProvider.allCases.map(discover)
    }

    public func discover(_ provider: HarnessProvider) -> HarnessInstallation {
        #if DEBUG
        // Keep the override at discovery so startup, Settings, and refresh agree.
        if simulateNoHarnesses {
            let executable = externalInstallChecks.contains(provider)
                ? standaloneCandidates(for: provider).first(where: isExecutable) : nil
            return HarnessInstallation(provider: provider, executablePath: executable?.path)
        }
        #endif
        let executable = executableCandidates(for: provider).first(where: isExecutable)
        return HarnessInstallation(provider: provider, executablePath: executable?.path)
    }

    #if DEBUG
    /// Explicitly checking a completed external install never enables app-bundled fallbacks.
    public mutating func checkExternalInstallationDuringSimulation(_ provider: HarnessProvider) {
        externalInstallChecks.insert(provider)
    }
    #endif

    private func executableCandidates(for provider: HarnessProvider) -> [URL] {
        switch provider {
        case .codex:
            return standaloneCandidates(for: provider) + [
                applicationsDirectory.appendingPathComponent("ChatGPT.app/Contents/Resources/codex"),
                applicationsDirectory.appendingPathComponent("Codex.app/Contents/Resources/codex")
            ]
        }
    }

    private func standaloneCandidates(for provider: HarnessProvider) -> [URL] {
        switch provider {
        // The package location is accessible through the existing ~/.codex grant,
        // even when the sandbox cannot traverse the shell's ~/.local/bin symlink.
        case .codex: return [standaloneCodexURL] + executableSearchDirectories.map { $0.appendingPathComponent("codex") }
        }
    }

    private func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) &&
            !isDirectory.boolValue &&
            FileManager.default.isExecutableFile(atPath: url.path)
    }
}

public enum AgentRuntimePhase: String, Codable, Hashable, Sendable {
    case offline
    case starting
    case ready
    case working
    case failed
}

public struct AgentRuntimeSnapshot: Codable, Hashable, Sendable {
    public let agentID: UUID
    public var phase: AgentRuntimePhase
    public var detail: String
    public var processIdentifier: Int32?

    public init(
        agentID: UUID,
        phase: AgentRuntimePhase,
        detail: String,
        processIdentifier: Int32? = nil
    ) {
        self.agentID = agentID
        self.phase = phase
        self.detail = detail
        self.processIdentifier = processIdentifier
    }
}
