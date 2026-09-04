import Foundation

public enum HarnessProvider: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case codex
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    public var symbolName: String {
        switch self {
        case .codex: return "terminal.fill"
        case .claude: return "brain.head.profile.fill"
        }
    }
}

public enum HarnessReadiness: String, Codable, Hashable, Sendable {
    case ready
    case engineOnly
    case applicationOnly
    case unavailable
}

public struct HarnessInstallation: Identifiable, Codable, Hashable, Sendable {
    public let provider: HarnessProvider
    public let applicationPath: String?
    public let enginePath: String?
    public let acpAdapterPath: String?

    public init(
        provider: HarnessProvider,
        applicationPath: String?,
        enginePath: String?,
        acpAdapterPath: String?
    ) {
        self.provider = provider
        self.applicationPath = applicationPath
        self.enginePath = enginePath
        self.acpAdapterPath = acpAdapterPath
    }

    public var id: String { provider.id }

    public var readiness: HarnessReadiness {
        if acpAdapterPath != nil { return .ready }
        if enginePath != nil { return .engineOnly }
        if applicationPath != nil { return .applicationOnly }
        return .unavailable
    }

    public var detail: String {
        switch readiness {
        case .ready:
            return "ACP ready"
        case .engineOnly:
            return "Harness found · ACP adapter needed"
        case .applicationOnly:
            return "Application found · command-line harness unavailable"
        case .unavailable:
            return "Not installed"
        }
    }
}

public struct HarnessDiscovery: Sendable {
    private let homeDirectory: URL
    private let applicationsDirectory: URL
    private let executableSearchDirectories: [URL]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        executableSearchDirectories: [URL]? = nil
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.applicationsDirectory = applicationsDirectory.standardizedFileURL
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
        let application = firstExisting(applicationCandidates(for: provider), executable: false)
        let engine = firstExisting(engineCandidates(for: provider), executable: true)
        let adapter = firstExisting(adapterCandidates(for: provider), executable: true)
        return HarnessInstallation(
            provider: provider,
            applicationPath: application?.path,
            enginePath: engine?.path,
            acpAdapterPath: adapter?.path
        )
    }

    private func applicationCandidates(for provider: HarnessProvider) -> [URL] {
        switch provider {
        case .codex:
            return [
                applicationsDirectory.appendingPathComponent("ChatGPT.app", isDirectory: true),
                applicationsDirectory.appendingPathComponent("Codex.app", isDirectory: true)
            ]
        case .claude:
            return [applicationsDirectory.appendingPathComponent("Claude.app", isDirectory: true)]
        }
    }

    private func engineCandidates(for provider: HarnessProvider) -> [URL] {
        let name = provider.rawValue
        var candidates = executableSearchDirectories.map { $0.appendingPathComponent(name) }
        switch provider {
        case .codex:
            candidates.insert(
                applicationsDirectory.appendingPathComponent("ChatGPT.app/Contents/Resources/codex"),
                at: 0
            )
            candidates.insert(
                applicationsDirectory.appendingPathComponent("Codex.app/Contents/Resources/codex"),
                at: 1
            )
        case .claude:
            candidates.insert(
                applicationsDirectory.appendingPathComponent("Claude.app/Contents/Resources/claude"),
                at: 0
            )
        }
        return candidates
    }

    private func adapterCandidates(for provider: HarnessProvider) -> [URL] {
        let name = provider == .codex ? "codex-acp" : "claude-agent-acp"
        return executableSearchDirectories.map { $0.appendingPathComponent(name) }
    }

    private func firstExisting(_ candidates: [URL], executable: Bool) -> URL? {
        candidates.first { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return false
            }
            return executable ? !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: url.path) : true
        }
    }
}

public enum AgentRuntimePhase: String, Codable, Hashable, Sendable {
    case offline
    case waitingForAdapter
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
