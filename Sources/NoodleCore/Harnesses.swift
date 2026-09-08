import Foundation

public enum HarnessProvider: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case codex
    case claudeCode = "claude-code"
    case fx
    case grokBuild = "grok-build"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .fx: return "FX"
        case .grokBuild: return "Grok Build"
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

/// Claude Code does not expose its interactive `/model` picker as a machine-readable
/// command. Keep its standard model aliases available without duplicating the CLI's
/// changing version catalogue.
public enum ClaudeCodeCapabilities {
    public static let efforts = [
        HarnessEffort(id: "low", description: "Faster responses with less reasoning."),
        HarnessEffort(id: "medium", description: "Balanced reasoning."),
        HarnessEffort(id: "high", description: "More thorough reasoning."),
        HarnessEffort(id: "xhigh", description: "Extended reasoning for difficult work."),
        HarnessEffort(id: "max", description: "Maximum available reasoning effort.")
    ]

    public static let models: [HarnessModel] = [
        model("fable", "Fable", "The latest Fable model for the hardest, longest-running tasks."),
        model("opus", "Opus", "The latest Opus model for complex reasoning and large changes."),
        model("sonnet", "Sonnet", "The latest Sonnet model for everyday coding work.", isDefault: true),
        model("haiku", "Haiku", "The latest fast model for quick and mechanical work.")
    ]

    public static func isValidModelIdentifier(_ identifier: String) -> Bool {
        models.contains { $0.id == identifier }
    }

    private static func model(
        _ id: String,
        _ displayName: String,
        _ description: String,
        isDefault: Bool = false
    ) -> HarnessModel {
        HarnessModel(
            id: id,
            displayName: displayName,
            description: description,
            supportedEfforts: efforts,
            defaultEffort: "high",
            isDefault: isDefault
        )
    }
}

public struct HarnessDiscovery: Sendable {
    private let applicationsDirectory: URL
    private let executableSearchDirectories: [URL]
    private let standaloneCodexURL: URL
    private let standaloneClaudeURL: URL
    private let standaloneFxURL: URL
    private let standaloneGrokURL: URL
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
        self.standaloneClaudeURL = homeDirectory.appendingPathComponent(".local/bin/claude")
        self.standaloneFxURL = homeDirectory.appendingPathComponent(".local/bin/fx")
        self.standaloneGrokURL = homeDirectory.appendingPathComponent(".grok/bin/grok")
        self.executableSearchDirectories = executableSearchDirectories ?? [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        ]
    }

    public func discover() -> [HarnessInstallation] {
        HarnessProvider.allCases.map(discover)
    }

    public func allowsHostDiscovery(for provider: HarnessProvider) -> Bool {
        #if DEBUG
        return !simulateNoHarnesses || externalInstallChecks.contains(provider)
        #else
        return true
        #endif
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
        case .claudeCode, .fx, .grokBuild:
            return standaloneCandidates(for: provider)
        }
    }

    private func standaloneCandidates(for provider: HarnessProvider) -> [URL] {
        switch provider {
        // The package location is accessible through the existing ~/.codex grant,
        // even when the sandbox cannot traverse the shell's ~/.local/bin symlink.
        case .codex: return [standaloneCodexURL] + executableSearchDirectories.map { $0.appendingPathComponent("codex") }
        case .claudeCode:
            return [standaloneClaudeURL] + executableSearchDirectories
                .map { $0.appendingPathComponent("claude") }
                .filter { $0.standardizedFileURL != standaloneClaudeURL.standardizedFileURL }
        case .fx: return [standaloneFxURL]
        case .grokBuild: return [standaloneGrokURL]
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

public enum AgentSleepPolicy {
    public static func shouldPreventIdleSleep(
        enabled: Bool,
        phases: some Sequence<AgentRuntimePhase>
    ) -> Bool {
        enabled && phases.contains(.working)
    }
}
